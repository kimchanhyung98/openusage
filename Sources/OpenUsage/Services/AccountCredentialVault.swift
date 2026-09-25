import Foundation

/// 계정 전환에 쓰이는 인증 snapshot의 전용 Keychain 저장소 — 앱 구현 세부사항.
/// profile metadata·로그·UI 상태에 값 포함 금지.
struct AccountCredentialVault {
    struct Entry: Codable, Equatable, Sendable {
        var credential: String
        var claudeOAuthAccount: String?
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
        let value = try keychain.readAppOwnedPassword(
            service: service, forCurrentUser: true, allowInteraction: allowInteraction
        ) ?? keychain.readAppOwnedPassword(
            service: service, forCurrentUser: false, allowInteraction: allowInteraction
        )
        guard let value else { return nil }
        // 기존 hex 인코딩 snapshot도 호환.
        guard let entry = ProviderParse.decodeJSONWithHexFallback(value, as: Entry.self) else {
            throw AccountCredentialVaultError.missingEntry
        }
        return entry
    }

    func save(_ entry: Entry, profile: AccountProfile) throws {
        let data = try JSONEncoder().encode(entry)
        try keychain.writeGenericPasswordForCurrentUser(
            service: service(for: profile),
            value: String(decoding: data, as: UTF8.self)
        )
    }

    func replaceCredential(
        _ credential: String, family: String, profileID: String, allowInteraction: Bool = false
    ) throws {
        guard var entry = try load(family: family, profileID: profileID, allowInteraction: allowInteraction) else {
            throw AccountCredentialVaultError.missingEntry
        }
        entry.credential = credential
        let data = try JSONEncoder().encode(entry)
        try keychain.writeGenericPasswordForCurrentUser(
            service: Self.service(family: family, profileID: profileID),
            value: String(decoding: data, as: UTF8.self)
        )
    }

    func delete(profile: AccountProfile) throws {
        try keychain.deleteGenericPassword(service: service(for: profile))
    }

    static func service(family: String, profileID: String) -> String {
        "OpenUsage Account Authentication v1 \(family) \(profileID)"
    }

    private func service(for profile: AccountProfile) -> String {
        Self.service(family: profile.family, profileID: profile.id)
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
