import CryptoKit
import Darwin
import Foundation

/// 사용량 endpoint·계정별 조회 잠금과 429 대기·마지막 정상 사용량을 앱과 CLI 사이에 공유.
struct ClaudeUsageStateStore: Sendable {
    struct AuthenticationFailure: Codable, Sendable {
        private enum Kind: String, Codable, Sendable {
            case sessionExpired, tokenExpired, desktopTokenExpired

            var error: ClaudeAuthError {
                switch self {
                case .sessionExpired: .sessionExpired
                case .tokenExpired: .tokenExpired
                case .desktopTokenExpired: .desktopTokenExpired
                }
            }
        }

        private let kind: Kind
        private let credentialFingerprint: String

        init?(_ error: Error, credentials: ClaudeOAuth, config: ClaudeOAuthConfig) {
            switch error {
            case ClaudeAuthError.sessionExpired: kind = .sessionExpired
            case ClaudeAuthError.tokenExpired: kind = .tokenExpired
            case ClaudeAuthError.desktopTokenExpired: kind = .desktopTokenExpired
            default: return nil
            }
            credentialFingerprint = Self.fingerprint(credentials, config: config)
        }

        func error(matching credentials: ClaudeOAuth, config: ClaudeOAuthConfig) -> ClaudeAuthError? {
            credentialFingerprint == Self.fingerprint(credentials, config: config) ? kind.error : nil
        }

        // 같은 계정의 다른 로그인·OAuth client까지 만료로 오판하지 않으며 토큰 원문은 저장하지 않음.
        private static func fingerprint(_ credentials: ClaudeOAuth, config: ClaudeOAuthConfig) -> String {
            let values = [config.refreshURL.absoluteString, config.clientID,
                          credentials.accessToken ?? "", credentials.refreshToken ?? ""]
            let input = values.map { "\($0.utf8.count):\($0)" }.joined()
            return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Record: Codable, Sendable {
        var version = 1
        var consecutiveRateLimits = 0
        var retryAfter: Date?
        var lastGood: ClaudeMappedUsage?
        var lastFailure: ClaudeUsageError?
        var authenticationFailure: AuthenticationFailure?
        var completedAt: Date?

        mutating func rateLimited(now: Date, retryAfterSeconds: Int?) {
            consecutiveRateLimits = min(consecutiveRateLimits + 1, 3)
            let minimum = RefreshSetting.slowInterval * pow(2, Double(consecutiveRateLimits - 1))
            retryAfter = now.addingTimeInterval(max(minimum, Double(retryAfterSeconds ?? 0)))
            lastFailure = nil
            authenticationFailure = nil
            completedAt = now
        }

        mutating func succeeded(_ usage: ClaudeMappedUsage, at date: Date) {
            lastGood = usage
            lastFailure = nil
            authenticationFailure = nil
            consecutiveRateLimits = 0
            retryAfter = nil
            completedAt = date
        }

        mutating func failed(_ error: ClaudeUsageError, at date: Date) {
            lastFailure = error
            authenticationFailure = nil
            completedAt = date
        }

        mutating func failed(_ error: AuthenticationFailure, at date: Date) {
            lastFailure = nil
            authenticationFailure = error
            completedAt = date
        }
    }

    enum StoreError: Error, LocalizedError, CategorizedError {
        case identityUnavailable, invalidRecord, storageUnavailable, busy

        var errorCategory: ErrorCategory { .other }
        var errorDescription: String? {
            switch self {
            case .identityUnavailable:
                "Claude account identity could not be verified. Sign in again before refreshing usage."
            case .invalidRecord:
                "Claude usage retry data could not be read. Check the app log before retrying."
            case .storageUnavailable:
                "Claude usage retry data could not be saved or opened. Check the app log and try again."
            case .busy:
                "Another Claude usage request is still running. Try again after it finishes."
            }
        }
    }

    /// 잠금 파일은 삭제하지 않으며 descriptor 종료 시 프로세스 간 잠금 자동 해제.
    final class Lease: @unchecked Sendable {
        let waited: Bool
        private let descriptor: Int32
        private let fileURL: URL

        fileprivate init(descriptor: Int32, fileURL: URL, waited: Bool) {
            self.descriptor = descriptor
            self.fileURL = fileURL
            self.waited = waited
        }

        deinit { Darwin.close(descriptor) }

        func read() throws -> Record {
            do {
                guard FileManager.default.fileExists(atPath: fileURL.path) else { return Record() }
                let data = try Data(contentsOf: fileURL)
                let record = try JSONDecoder().decode(Record.self, from: data)
                guard record.version == 1, (0...3).contains(record.consecutiveRateLimits),
                      (record.retryAfter == nil) == (record.consecutiveRateLimits == 0),
                      record.retryAfter.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                      record.completedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true,
                      record.lastFailure == nil || record.completedAt != nil,
                      record.authenticationFailure == nil || (record.lastFailure == nil && record.completedAt != nil),
                      record.lastGood.map({ $0.quotaObservedAt != nil && $0.retryAfter == nil }) ?? true
                else { throw StoreError.invalidRecord }
                return record
            } catch {
                AppLog.error(LogTag.plugin("claude"), "usage retry state read failed: \(error.localizedDescription)")
                throw StoreError.invalidRecord
            }
        }

        func save(_ record: Record) throws {
            let temporary = fileURL.appendingPathExtension(UUID().uuidString)
            do {
                let data = try JSONEncoder().encode(record)
                let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw StoreError.storageUnavailable }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer {
                    try? handle.close()
                    try? FileManager.default.removeItem(at: temporary)
                }
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
                guard Darwin.rename(temporary.path, fileURL.path) == 0 else { throw StoreError.storageUnavailable }
            } catch {
                AppLog.error(LogTag.plugin("claude"), "usage retry state write failed: \(error.localizedDescription)")
                throw StoreError.storageUnavailable
            }
        }
    }

    let directory: URL
    private let onContention: @Sendable () -> Void

    init(
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenUsage/claude-usage-state"),
        onContention: @escaping @Sendable () -> Void = {}
    ) {
        self.directory = directory
        self.onContention = onContention
    }

    func acquire(accountKey: String, usageURL: URL) async throws -> Lease {
        let key = SHA256.hash(data: Data("claude-oauth-usage\u{0}\(usageURL.absoluteString)\u{0}\(accountKey)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fileURL = directory.appendingPathComponent(key).appendingPathExtension("json")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            AppLog.error(LogTag.plugin("claude"), "usage retry directory unavailable: \(error.localizedDescription)")
            throw StoreError.storageUnavailable
        }
        let descriptor = Darwin.open(
            fileURL.appendingPathExtension("lock").path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            AppLog.error(LogTag.plugin("claude"), "usage retry lock open failed (errno=\(errno))")
            throw StoreError.storageUnavailable
        }
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(120))
        var waited = false
        do {
            while true {
                try Task.checkCancellation()
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    return Lease(descriptor: descriptor, fileURL: fileURL, waited: waited)
                }
                guard errno == EWOULDBLOCK || errno == EINTR else {
                    AppLog.error(LogTag.plugin("claude"), "usage retry lock failed (errno=\(errno))")
                    throw StoreError.storageUnavailable
                }
                guard clock.now < deadline else { throw StoreError.busy }
                if !waited { onContention() }
                waited = true
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }
}
