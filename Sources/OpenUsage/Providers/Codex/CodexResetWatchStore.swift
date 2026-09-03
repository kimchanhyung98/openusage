import Foundation

struct CodexResetWatch: Equatable, Sendable {
    let chancePercent: Double
    let deadline: Date
}

typealias CodexResetWatchLoading = @Sendable () async -> CodexResetWatch?

/// Codex usage와 독립된 Reset Watch 활성 상태·15분 조회 주기 소유자.
@MainActor
final class CodexResetWatchCoordinator {
    static let refreshInterval = RefreshSetting.interval * 3

    typealias Waiting = @Sendable (Duration) async -> Bool

    private let load: CodexResetWatchLoading
    private let publish: @MainActor (CodexResetWatch?) -> Void
    private let interval: Duration
    private let wait: Waiting
    private var isActive = false
    private var task: Task<Void, Never>?

    init(
        load: @escaping CodexResetWatchLoading = { await CodexResetWatchStore.shared.current() },
        publish: @escaping @MainActor (CodexResetWatch?) -> Void,
        interval: Duration = .seconds(CodexResetWatchCoordinator.refreshInterval),
        wait: @escaping Waiting = { duration in
            do {
                try await Task.sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) {
        self.load = load
        self.publish = publish
        self.interval = interval
        self.wait = wait
    }

    deinit { task?.cancel() }

    /// 활성 전환 시 즉시 조회 후 독립 주기 반복, 비활성 전환 시 표시 값과 예약 작업 제거.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        task?.cancel()
        task = nil

        guard active else {
            publish(nil)
            return
        }

        let load = self.load
        let publish = self.publish
        let interval = self.interval
        let wait = self.wait
        task = Task {
            while !Task.isCancelled {
                let watch = await load()
                guard !Task.isCancelled else { return }
                publish(watch)
                guard await wait(interval), !Task.isCancelled else { return }
            }
        }
    }
}

/// 공개 Reset Watch 응답의 검증·ETag·backoff·single-flight 소유자.
actor CodexResetWatchStore {
    static let shared = CodexResetWatchStore()

    private static let fallbackFreshAge: TimeInterval = 60
    private static let maximumFreshAge: TimeInterval = 5 * 60
    private static let fallbackStaleAge: TimeInterval = 5 * 60
    private static let maximumStaleAge: TimeInterval = 5 * 60
    private static let failureRetryAge: TimeInterval = 60
    private static let rateLimitFallbackAge: TimeInterval = 5 * 60
    private static let maximumRetryAge: TimeInterval = 5 * 60

    private enum Representation: Sendable {
        case watch(CodexResetWatch)
        case absent
    }

    private struct CachePolicy: Sendable {
        let freshAge: TimeInterval
        let staleAge: TimeInterval

        static let fallback = CachePolicy(
            freshAge: CodexResetWatchStore.fallbackFreshAge,
            staleAge: CodexResetWatchStore.fallbackStaleAge
        )
    }

    private let http: any HTTPClient
    private let endpoint: URL
    private let now: @Sendable () -> Date

    private var representation: Representation?
    private var etag: String?
    private var freshUntil = Date.distantPast
    private var staleUntil = Date.distantPast
    private var retryNotBefore = Date.distantPast
    private var lastPolicy = CachePolicy.fallback
    private var refreshTask: Task<CodexResetWatch?, Never>?

    init(
        http: any HTTPClient = URLSessionHTTPClient(sendsCookies: false),
        endpoint: URL = URL(string: "https://codex-resets.com/api/v1/status")!,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.endpoint = endpoint
        self.now = now
    }

    /// 현재 유효한 forecast — 외부 장애 시 마지막 유효 값 유지, provider refresh와 분리.
    func current() async -> CodexResetWatch? {
        let readAt = now()
        if case .watch(let watch) = representation, readAt >= watch.deadline {
            representation = nil
            etag = nil
            freshUntil = .distantPast
            staleUntil = .distantPast
        }
        if readAt < freshUntil {
            return watchIfUsable(at: readAt, validUntil: freshUntil)
        }
        if readAt < retryNotBefore {
            return watchIfUsable(at: readAt, validUntil: staleUntil)
        }

        if refreshTask == nil {
            refreshTask = Task { await self.refresh() }
        }
        guard let refreshTask else { return nil }
        return await refreshTask.value
    }

    private func watchIfUsable(at date: Date, validUntil: Date) -> CodexResetWatch? {
        guard date < validUntil, case .watch(let watch) = representation, date < watch.deadline else {
            return nil
        }
        return watch
    }

    private func refresh() async -> CodexResetWatch? {
        defer { refreshTask = nil }

        var request = HTTPRequest(method: "GET", url: endpoint, timeout: 8)
        request.headers = [
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ]
        if representation != nil, let etag {
            request.headers["If-None-Match"] = etag
        }

        do {
            let response = try await http.send(request)
            let receivedAt = now()
            switch response.statusCode {
            case 200:
                let decoded = try Self.decodeRepresentation(response.body, at: receivedAt)
                let policy = Self.cachePolicy(response.header("cache-control"), fallback: lastPolicy)
                representation = decoded
                etag = response.header("etag")
                lastPolicy = policy
                applyFreshness(policy, receivedAt: receivedAt, representation: decoded)
                retryNotBefore = .distantPast
                return watch(from: decoded, at: now())
            case 304:
                guard let representation else { throw FetchError.notModifiedWithoutCache }
                let policy = Self.cachePolicy(response.header("cache-control"), fallback: lastPolicy)
                if let responseETag = response.header("etag") { etag = responseETag }
                lastPolicy = policy
                applyFreshness(policy, receivedAt: receivedAt, representation: representation)
                retryNotBefore = .distantPast
                return watch(from: representation, at: now())
            case 429:
                let retrySeconds = Self.retryAfterSeconds(response, now: receivedAt)
                    ?? Self.rateLimitFallbackAge
                retryNotBefore = receivedAt.addingTimeInterval(retrySeconds)
                extendStaleUntilRetry()
                AppLog.warn(LogTag.plugin("codex"), "Reset Watch rate limited; retry deferred")
                return representation.flatMap { watch(from: $0, at: now()) }
            default:
                throw FetchError.httpStatus(response.statusCode)
            }
        } catch is CancellationError {
            return nil
        } catch {
            let failedAt = now()
            retryNotBefore = failedAt.addingTimeInterval(Self.failureRetryAge)
            extendStaleUntilRetry()
            AppLog.warn(LogTag.plugin("codex"), "Reset Watch refresh failed; keeping valid cached data: \(error.localizedDescription)")
            return representation.flatMap { watch(from: $0, at: now()) }
        }
    }

    private func watch(from representation: Representation, at date: Date) -> CodexResetWatch? {
        guard case .watch(let watch) = representation, date < watch.deadline else { return nil }
        return watch
    }

    private func extendStaleUntilRetry() {
        guard case .watch(let watch) = representation else { return }
        staleUntil = min(max(staleUntil, retryNotBefore), watch.deadline)
    }

    private func applyFreshness(
        _ policy: CachePolicy,
        receivedAt: Date,
        representation: Representation
    ) {
        var nextFresh = receivedAt.addingTimeInterval(policy.freshAge)
        var nextStale = nextFresh.addingTimeInterval(policy.staleAge)
        if case .watch(let watch) = representation {
            nextFresh = min(nextFresh, watch.deadline)
            nextStale = min(nextStale, watch.deadline)
        }
        freshUntil = nextFresh
        staleUntil = nextStale
    }

    private static func decodeRepresentation(_ body: Data, at date: Date) throws -> Representation {
        let payload = try JSONDecoder().decode(StatusPayload.self, from: body)
        guard let activeWatch = payload.data.activeWatch,
              let chance = activeWatch.resetChancePercent
        else {
            return .absent
        }
        guard (0...100).contains(chance) else { throw FetchError.invalidChance }
        guard let deadline = OpenUsageISO8601.date(from: activeWatch.expiresAt) else {
            throw FetchError.invalidDeadline
        }
        guard deadline > date else { return .absent }
        return .watch(CodexResetWatch(chancePercent: Double(chance), deadline: deadline))
    }

    private static func cachePolicy(_ value: String?, fallback: CachePolicy) -> CachePolicy {
        let directives = value?.split(separator: ",").reduce(into: [String: TimeInterval]()) { result, part in
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            guard pair.count == 2,
                  let seconds = TimeInterval(pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))),
                  seconds >= 0
            else { return }
            result[pair[0]] = seconds
        } ?? [:]
        let fresh = min(directives["max-age"] ?? fallback.freshAge, maximumFreshAge)
        let stale = min(directives["stale-while-revalidate"] ?? fallback.staleAge, maximumStaleAge)
        return CachePolicy(freshAge: fresh, staleAge: stale)
    }

    private static func retryAfterSeconds(_ response: HTTPResponse, now: Date) -> TimeInterval? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return min(seconds, maximumRetryAge)
        }
        guard let date = ResetWatchHTTPDateFormatter.date(from: raw) else { return nil }
        return min(max(0, date.timeIntervalSince(now)), maximumRetryAge)
    }
}

private enum ResetWatchHTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

private struct StatusPayload: Decodable {
    let data: DataPayload

    struct DataPayload: Decodable {
        let activeWatch: ActiveWatch?

        private enum CodingKeys: String, CodingKey {
            case activeWatch = "active_watch"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.activeWatch) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.activeWatch,
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing active_watch")
                )
            }
            activeWatch = try container.decodeIfPresent(ActiveWatch.self, forKey: .activeWatch)
        }
    }

    struct ActiveWatch: Decodable {
        let resetChancePercent: Int?
        let expiresAt: String

        private enum CodingKeys: String, CodingKey {
            case resetChancePercent = "reset_chance_percent"
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard container.contains(.resetChancePercent) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.resetChancePercent,
                    .init(codingPath: decoder.codingPath, debugDescription: "Missing reset_chance_percent")
                )
            }
            resetChancePercent = try container.decodeIfPresent(Int.self, forKey: .resetChancePercent)
            expiresAt = try container.decode(String.self, forKey: .expiresAt)
        }
    }
}

private enum FetchError: Error, LocalizedError {
    case httpStatus(Int)
    case notModifiedWithoutCache
    case invalidChance
    case invalidDeadline

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): return "HTTP \(status)"
        case .notModifiedWithoutCache: return "HTTP 304 without cached Reset Watch data"
        case .invalidChance: return "Reset Watch chance was outside 0...100"
        case .invalidDeadline: return "Reset Watch deadline was invalid"
        }
    }
}
