import Foundation

/// Private Keychain storage for the authentication snapshots used by account switching. It is an
/// implementation detail of the app: profile metadata, logs, and UI state never contain the value.
struct AccountCredentialVault {
    struct Entry: Codable, Equatable, Sendable {
        var credential: String
        var claudeOAuthAccount: String?
    }

    private let keychain: KeychainAccessing

    init(keychain: KeychainAccessing = SecurityKeychainAccessor()) {
        self.keychain = keychain
    }

    func contains(profile: AccountProfile) -> Bool {
        keychain.genericPasswordExists(service: service(for: profile)) == true
    }

    func load(profile: AccountProfile) throws -> Entry? {
        try load(family: profile.family, profileID: profile.id)
    }

    func load(family: String, profileID: String) throws -> Entry? {
        let service = Self.service(family: family, profileID: profileID)
        let value = try keychain.readGenericPasswordForCurrentUser(service: service)
            ?? keychain.readGenericPassword(service: service)
        guard let value else { return nil }
        // `security find-generic-password -w` prints hex for non-ASCII payloads (an org name in the
        // Claude oauthAccount is enough), so the read needs the same fallback the provider auth
        // stores use.
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

    func replaceCredential(_ credential: String, family: String, profileID: String) throws {
        guard var entry = try load(family: family, profileID: profileID) else {
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

enum AccountCredentialVaultError: Error {
    case missingEntry
}
