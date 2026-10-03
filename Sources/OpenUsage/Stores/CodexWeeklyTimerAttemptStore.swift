import CryptoKit
import Darwin
import Foundation

struct CodexWeeklyTimerAttempt: Codable, Equatable, Sendable {
    enum Execution: String, Codable, Sendable {
        case pending, completed, failed
    }

    var id: UUID
    var attemptedAt: Date
    var resetBefore: Date?
    var resetAfter: Date?
    var execution: Execution
    var notBefore: Date
    var lastVerifiedAt: Date?
}

enum CodexWeeklyTimerObservationChange: Equatable {
    case stale, baseline, incomparable, unchanged, changed
}

/// 전송 전 기록을 원자적으로 저장 — 손상·읽기 실패 시 기존 중복 방지 기록을 버리지 않음.
@MainActor
final class CodexWeeklyTimerAttemptStore {
    static let retryCooldown: TimeInterval = 5 * 60

    private struct FreshObservation: Codable, Equatable {
        var rawResetAt: Date?
        var observedAt: Date
        var stableSince: Date?
        var stableResetAt: Date?
        var lastObservedAt: Date?
        var usedPercent: Double?
    }

    private struct Document: Codable {
        var version = 2
        var attempts: [String: CodexWeeklyTimerAttempt] = [:]
        var observations: [String: FreshObservation] = [:]

        enum CodingKeys: CodingKey { case version, attempts, observations }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            attempts = try container.decode([String: CodexWeeklyTimerAttempt].self, forKey: .attempts)
            observations = try container.decodeIfPresent([String: FreshObservation].self, forKey: .observations) ?? [:]
        }
    }

    private enum StoreError: Error {
        case invalidDocument
    }

    let fileURL: URL

    init(fileURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OpenUsage/codex-weekly-timer-attempts.json")) {
        self.fileURL = fileURL
    }

    func attempt(for accountKey: String) throws -> CodexWeeklyTimerAttempt? {
        try withLock { try read().attempts[Self.key(accountKey)] }
    }

    /// 계정·기본 주간 버킷의 예약과 기존 보류 확인을 같은 파일 잠금 안에서 수행.
    func begin(
        accountKey: String, resetBefore: Date?, now: Date, expectedObservedAt: Date? = nil
    ) throws -> CodexWeeklyTimerAttempt? {
        try withLock {
            var document = try read()
            let key = Self.key(accountKey)
            guard document.attempts[key].map({ $0.notBefore <= now }) ?? true else { return nil }
            if let expectedObservedAt,
               document.observations[key]?.observedAt != expectedObservedAt { return nil }
            let attempt = CodexWeeklyTimerAttempt(
                id: UUID(), attemptedAt: now, resetBefore: resetBefore, resetAfter: nil,
                execution: .pending,
                notBefore: now.addingTimeInterval(Self.retryCooldown),
                lastVerifiedAt: nil
            )
            document.attempts[key] = attempt
            try write(document)
            return attempt
        }
    }

    func update(accountKey: String, attempt: CodexWeeklyTimerAttempt) throws {
        try withLock {
            var document = try read()
            let key = Self.key(accountKey)
            guard document.attempts[key]?.id == attempt.id else { return }
            document.attempts[key] = attempt
            try write(document)
        }
    }

    /// 절대 reset_at만 비교하고 이전 정상 조회를 교체 — 실행 보류 시각은 변경하지 않음.
    func observe(
        accountKey: String, rawResetAt: Date?, observedAt: Date, usedPercent: Double = 0
    ) throws -> CodexWeeklyTimerObservationChange {
        try withLock {
            var document = try read()
            let key = Self.key(accountKey)
            let previous = document.observations[key]
            if let previous, observedAt <= (previous.lastObservedAt ?? previous.observedAt) { return .stale }
            // 허용 범위 안에서는 최초 기준 유지 — 조금씩 이동하는 리셋을 고정으로 오판하지 않음.
            let previousReset = previous?.stableResetAt ?? previous?.rawResetAt
            let sameReset = CodexWeeklyTimerObservation.resetTimesMatch(previousReset, rawResetAt)
            let stableSince = sameReset ? (previous?.stableSince ?? previous?.observedAt) : observedAt
            if var previous, sameReset, usedPercent == 0, (previous.usedPercent ?? 0) == 0,
               observedAt.timeIntervalSince(stableSince ?? observedAt) <= CodexWeeklyTimerObservation.resetTimeTolerance {
                previous.lastObservedAt = observedAt
                document.observations[key] = previous
                try write(document)
                return .incomparable
            }
            document.observations[key] = FreshObservation(
                rawResetAt: rawResetAt, observedAt: observedAt, stableSince: rawResetAt == nil ? nil : stableSince,
                stableResetAt: sameReset ? previousReset : rawResetAt,
                lastObservedAt: observedAt, usedPercent: usedPercent
            )
            try write(document)
            guard let previous else { return .baseline }
            guard previous.rawResetAt != nil, rawResetAt != nil else { return .incomparable }
            guard sameReset else { return .changed }
            return observedAt.timeIntervalSince(stableSince ?? observedAt) > CodexWeeklyTimerObservation.resetTimeTolerance
                ? .unchanged : .incomparable
        }
    }

    func isLatest(_ observation: CodexWeeklyTimerObservation) throws -> Bool {
        try withLock {
            let latest = try read().observations[Self.key(observation.accountKey)]
            return latest?.rawResetAt == observation.rawResetAt && latest?.observedAt == observation.observedAt
        }
    }

    func latestObservationAt(accountKey: String) throws -> Date? {
        try withLock { try read().observations[Self.key(accountKey)]?.observedAt }
    }

    private static func key(_ accountKey: String) -> String {
        SHA256.hash(data: Data("codex-default-weekly\u{0}\(accountKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private func read() throws -> Document {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError {
            return Document()
        }
        var document = try JSONDecoder().decode(Document.self, from: data)
        guard [1, 2].contains(document.version), document.attempts.allSatisfy({ key, attempt in
            Self.isValidKey(key)
                && attempt.notBefore >= attempt.attemptedAt
        }), document.observations.keys.allSatisfy(Self.isValidKey) else { throw StoreError.invalidDocument }
        if document.version == 1 {
            for key in document.attempts.keys {
                guard var attempt = document.attempts[key] else { continue }
                attempt.notBefore = attempt.attemptedAt.addingTimeInterval(Self.retryCooldown)
                document.attempts[key] = attempt
            }
            document.version = 2
        }
        return document
    }

    private static func isValidKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func write(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func withLock<Value>(_ body: () throws -> Value) throws -> Value {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
