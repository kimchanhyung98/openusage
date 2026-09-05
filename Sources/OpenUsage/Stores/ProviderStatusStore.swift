import Foundation
import Observation

/// 공개 상태 API 결과를 provider family 단위로 보관하는 transient store.
@MainActor
@Observable
final class ProviderStatusStore {
    static let successTTL: TimeInterval = 5 * 60
    static let failureRetryDelay: TimeInterval = 5 * 60
    static let staleGracePeriod: TimeInterval = 15 * 60
    static let maximumRetryAfter: TimeInterval = 60 * 60

    private struct Entry {
        var status: ProviderServiceStatus = .unknown
        var lastSuccessfulAt: Date?
        var nextAutomaticAttemptAt: Date?
        var retryAfterUntil: Date?
    }

    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var statusesByFamily: [String: ProviderServiceStatus] = [:]

    @ObservationIgnored private let http: any HTTPClient
    @ObservationIgnored private let sourceFor: @MainActor (String) -> ProviderStatusSource?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var inFlight: [String: Flight] = [:]

    init(
        http: any HTTPClient = ProviderStatusHTTPClient(),
        sourceFor: @escaping @MainActor (String) -> ProviderStatusSource? = ProviderStatusSourceCatalog.source(for:),
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.http = http
        self.sourceFor = sourceFor
        self.now = now
    }

    func status(for providerID: String) -> ProviderServiceStatus {
        statusesByFamily[ProviderAccountID.family(of: providerID)] ?? .unknown
    }

    /// 같은 family의 card를 한 요청으로 합치고 서로 다른 family는 병렬 조회.
    func refresh(providerIDs: [String], force: Bool = false) async {
        var seenFamilies: Set<String> = []
        let families = providerIDs
            .map(ProviderAccountID.family(of:))
            .filter { seenFamilies.insert($0).inserted }
        var tasks: [Task<Void, Never>] = []
        tasks.reserveCapacity(families.count)

        for family in families {
            guard let source = sourceFor(family) else { continue }
            expireStaleStatus(for: family)

            if let flight = inFlight[family] {
                tasks.append(flight.task)
                continue
            }
            guard shouldAttempt(family: family, force: force) else { continue }

            let flightID = UUID()
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.fetch(source: source)
                self.finishFlight(family: family, id: flightID)
            }
            inFlight[family] = Flight(id: flightID, task: task)
            tasks.append(task)
        }

        for task in tasks {
            await task.value
        }
    }

    /// 재활성화 시 일반 실패 gate만 해제. 서버가 지정한 Retry-After와 fresh success TTL은 유지.
    func providerEnabled(_ providerID: String) {
        let family = ProviderAccountID.family(of: providerID)
        entries[family]?.nextAutomaticAttemptAt = nil
    }

    private func shouldAttempt(family: String, force: Bool) -> Bool {
        guard let entry = entries[family] else { return true }
        let currentDate = now()
        if let retryAfterUntil = entry.retryAfterUntil, currentDate < retryAfterUntil {
            return false
        }
        if !force,
           let nextAutomaticAttemptAt = entry.nextAutomaticAttemptAt,
           currentDate < nextAutomaticAttemptAt {
            return false
        }
        if !force,
           let lastSuccessfulAt = entry.lastSuccessfulAt,
           currentDate.timeIntervalSince(lastSuccessfulAt) < Self.successTTL {
            return false
        }
        return true
    }

    private func fetch(source: ProviderStatusSource) async {
        do {
            let response = try await http.send(HTTPRequest(method: "GET", url: source.endpointURL))
            guard !Task.isCancelled else {
                logCancellation(source: source)
                return
            }
            let checkedAt = now()
            let status = try source.decode(response, checkedAt: checkedAt)
            var entry = entries[source.familyID] ?? Entry()
            entry.status = status
            entry.lastSuccessfulAt = checkedAt
            entry.nextAutomaticAttemptAt = nil
            entry.retryAfterUntil = nil
            entries[source.familyID] = entry
            publish(status, for: source.familyID)
            AppLog.debug(.http, "provider-status \(source.familyID) \(source.endpointURL.host() ?? "unknown") ok")
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                logCancellation(source: source)
                return
            }
            recordFailure(error, source: source)
        }
    }

    private func logCancellation(source: ProviderStatusSource) {
        AppLog.debug(
            .http,
            "provider-status \(source.familyID) \(source.endpointURL.host() ?? "unknown") cancelled"
        )
    }

    private func recordFailure(_ error: Error, source: ProviderStatusSource) {
        let failedAt = now()
        var entry = entries[source.familyID] ?? Entry()
        entry.nextAutomaticAttemptAt = failedAt.addingTimeInterval(Self.failureRetryDelay)
        if case ProviderStatusSourceError.httpStatus(429, let rawRetryAfter) = error,
           let rawRetryAfter,
           let retryDate = Self.retryAfterDate(rawRetryAfter, relativeTo: failedAt) {
            entry.retryAfterUntil = retryDate
        }
        entries[source.familyID] = entry
        publish(entry.status, for: source.familyID)
        AppLog.warn(
            .http,
            "provider-status \(source.familyID) \(source.endpointURL.host() ?? "unknown") failed (\(Self.errorCategory(error)))"
        )
    }

    private func expireStaleStatus(for family: String) {
        guard var entry = entries[family],
              let lastSuccessfulAt = entry.lastSuccessfulAt,
              now().timeIntervalSince(lastSuccessfulAt) >= Self.staleGracePeriod,
              entry.status != .unknown
        else { return }
        entry.status = .unknown
        entries[family] = entry
        publish(.unknown, for: family)
    }

    private func publish(_ status: ProviderServiceStatus, for family: String) {
        guard statusesByFamily[family] != status else { return }
        if status == .unknown {
            statusesByFamily[family] = nil
        } else {
            statusesByFamily[family] = status
        }
    }

    private func finishFlight(family: String, id: UUID) {
        guard inFlight[family]?.id == id else { return }
        inFlight[family] = nil
    }

    private static func retryAfterDate(_ rawValue: String, relativeTo now: Date) -> Date? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: Date?
        if let seconds = TimeInterval(value), seconds >= 0 {
            candidate = now.addingTimeInterval(seconds)
        } else {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
            candidate = formatter.date(from: value)
        }
        guard let candidate, candidate > now else { return nil }
        return min(candidate, now.addingTimeInterval(Self.maximumRetryAfter))
    }

    private static func errorCategory(_ error: Error) -> String {
        if let error = error as? ProviderStatusSourceError {
            return error.category
        }
        if error is CancellationError {
            return "cancelled"
        }
        return "transport"
    }
}
