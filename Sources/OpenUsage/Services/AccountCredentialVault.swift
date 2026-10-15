import CryptoKit
import Foundation

/// 계정 전환에 쓰이는 인증 snapshot의 전용 Keychain 저장소 — 앱 구현 세부사항.
/// profile metadata·로그·UI 상태에 값 포함 금지.
struct AccountCredentialVault {
    struct Entry: Codable, Equatable, Sendable {
        var credential: String
        var claudeOAuthAccount: String?
        /// 연속 동기화 실패로 공유 홈에 남을 수 있는 이전 Codex 인증 후보 — 갱신된 snapshot의 역덮어쓰기 방지.
        var codexStaleSharedCredentialFingerprints: Set<String>? = nil

        /// 같은 identity의 이전 로그인과 구분하는 snapshot 전체 세대 증명.
        func snapshotDigest() throws -> String {
            struct Digest: Encodable {
                var credential: String
                var claudeOAuthAccount: String?
                var codexStaleSharedCredentialFingerprints: [String]?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let digest = Digest(
                credential: credential, claudeOAuthAccount: claudeOAuthAccount,
                codexStaleSharedCredentialFingerprints: codexStaleSharedCredentialFingerprints?.sorted()
            )
            return SHA256.hash(data: try encoder.encode(digest))
                .map { String(format: "%02x", $0) }.joined()
        }
    }

    private let keychain: KeychainAccessing

    init(keychain: KeychainAccessing = SecurityKeychainAccessor()) {
        self.keychain = keychain
    }

    /// 등록 계정의 snapshot은 존재 확인 실패만으로 제외하지 않음.
    func contains(profile: AccountProfile) -> Bool {
        keychain.genericPasswordExists(service: service(for: profile)) != false
    }

    func load(profile: AccountProfile, allowInteraction: Bool = false) throws -> Entry? {
        try load(family: profile.family, profileID: profile.id, allowInteraction: allowInteraction)
    }

    func load(family: String, profileID: String, allowInteraction: Bool = false) throws -> Entry? {
        let service = Self.service(family: family, profileID: profileID)
        let value: String?
        do {
            value = try keychain.readAppOwnedPassword(
                service: service, forCurrentUser: true, allowInteraction: allowInteraction
            ) ?? keychain.readAppOwnedPassword(
                service: service, forCurrentUser: false, allowInteraction: allowInteraction
            )
        } catch KeychainError.invalidData {
            throw AccountCredentialVaultError.missingEntry
        }
        guard let value else { return nil }
        // 기존 hex 인코딩 snapshot도 호환.
        guard let entry = ProviderParse.decodeJSONWithHexFallback(value, as: Entry.self) else {
            throw AccountCredentialVaultError.missingEntry
        }
        return entry
    }

    func save(_ entry: Entry, profile: AccountProfile, allowInteraction: Bool = false) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        try AccountCredentialMutation.withLock {
            let data = try JSONEncoder().encode(entry)
            try keychain.writeAppOwnedPassword(
                service: service(for: profile), value: String(decoding: data, as: UTF8.self),
                forCurrentUser: true, allowInteraction: allowInteraction
            )
        }
    }

    func replaceCredential(
        _ credential: String, family: String, profileID: String, allowInteraction: Bool = false,
        codexStaleSharedCredentialFingerprints: Set<String>? = nil
    ) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        try AccountCredentialMutation.withLock {
            guard var entry = try load(family: family, profileID: profileID, allowInteraction: allowInteraction) else {
                throw AccountCredentialVaultError.missingEntry
            }
            entry.credential = credential
            if family == "codex" {
                entry.codexStaleSharedCredentialFingerprints = codexStaleSharedCredentialFingerprints
            }
            let data = try JSONEncoder().encode(entry)
            try keychain.writeAppOwnedPassword(
                service: Self.service(family: family, profileID: profileID),
                value: String(decoding: data, as: UTF8.self),
                forCurrentUser: true, allowInteraction: allowInteraction
            )
        }
    }

    func delete(profile: AccountProfile) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        try AccountCredentialMutation.withLock {
            try keychain.deleteGenericPassword(service: service(for: profile))
        }
    }

    static func service(family: String, profileID: String) -> String {
        "OpenUsage Account Authentication v1 \(family) \(profileID)"
    }

    private func service(for profile: AccountProfile) -> String {
        Self.service(family: profile.family, profileID: profile.id)
    }
}

/// Codex 인증 비교·쓰기와 계정 전환의 프로세스 내부 직렬화 — 중첩 Vault 호출 허용, 비동기 요청 중 획득 금지.
enum AccountCredentialMutationLock {
    private static let lock = NSRecursiveLock()
    nonisolated(unsafe) private static var generation: UInt64 = 0

    static func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    static var revision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    static func acquire(family: String = "codex") {
        guard family == "codex" else { return }
        lock.lock()
        generation &+= 1
    }

    static func release(family: String = "codex") {
        if family == "codex" { lock.unlock() }
    }

    static func withUnchangedRevision(_ expected: UInt64, _ operation: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return false }
        generation &+= 1
        try operation()
        return true
    }

    /// credential 작업의 잠금 대기 없이 세대 확인 — 잠금·세대 충돌 시 commit 생략.
    static func withUnchangedRevisionIfAvailable(_ expected: UInt64, _ operation: () throws -> Void) rethrows -> Bool {
        guard lock.try() else { return false }
        defer { lock.unlock() }
        guard generation == expected else { return false }
        generation &+= 1
        try operation()
        return true
    }

}

public struct AccountCredentialSnapshotRemover: Sendable {
    private let keychain: any KeychainAccessing

    public init() {
        self.keychain = SecurityKeychainAccessor()
    }

    init(keychain: any KeychainAccessing) {
        self.keychain = keychain
    }

    public func remove(profile: AccountProfile) throws {
        try AccountCredentialVault(keychain: keychain).delete(profile: profile)
    }
}

enum AccountCredentialVaultError: Error, LocalizedError {
    case missingEntry

    var errorDescription: String? {
        "The saved sign-in is missing or invalid. Sign in again and retry."
    }
}
