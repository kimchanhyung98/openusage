import XCTest
@testable import OpenUsage

@MainActor
final class AccountSnapshotUsageTests: XCTestCase {
    func testClaudeSnapshotScopeReadsOnlyTheSavedProfileCredential() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "claude-default-home", family: "claude")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"personal-token"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        keychain.currentUserValues[ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))]
            = #"{"claudeAiOauth":{"accessToken":"work-token"}}"#

        let candidates = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        ).loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["personal-token"])
        XCTAssertEqual(candidates.map(\.source), [.accountSnapshot(profileID: profile.id)])
    }

    func testCodexSnapshotScopeReadsOnlyTheSavedProfileCredential() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "codex-default-home", family: "codex")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"tokens":{"access_token":"personal-token","account_id":"personal"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        keychain.values[CodexAuthStore.keychainService]
            = #"{"tokens":{"access_token":"work-token","account_id":"work"}}"#

        let candidates = CodexAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        ).loadAuthCandidates()

        XCTAssertEqual(candidates.map(\.auth.tokens?.accessToken), ["personal-token"])
        XCTAssertEqual(candidates.map(\.source), [.accountSnapshot(profileID: profile.id)])
    }

    func testCatalogBuildsReadOnlyRuntimesForSnapshotCards() {
        let cards = [
            AccountUsageSnapshotCard(
                id: "claude@profile-claude-default-home",
                profileID: "claude-default-home",
                family: "claude"
            ),
            AccountUsageSnapshotCard(
                id: "codex@profile-codex-default-home",
                profileID: "codex-default-home",
                family: "codex"
            )
        ]

        let runtimes = ProviderCatalog.make(snapshotCards: cards)

        let claude = runtimes.compactMap { $0 as? ClaudeProvider }
            .first { $0.provider.id == cards[0].id }
        let codex = runtimes.compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == cards[1].id }
        XCTAssertEqual(claude?.authStore.scope, .accountSnapshot(profileID: "claude-default-home"))
        XCTAssertEqual(codex?.authStore.scope, .accountSnapshot(profileID: "codex-default-home"))
    }

    func testClaudeTokenRotationPersistsBackToTheSameSnapshot() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "claude-default-home", family: "claude")
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"refresh"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"personal"}"#
            ),
            profile: profile
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        )
        let generation = store.credentialGeneration()
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        state.oauth.accessToken = "new-token"

        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        let entry = try XCTUnwrap(vault.load(profile: profile))
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(entry.credential)?.claudeAiOauth?.accessToken, "new-token")
        XCTAssertEqual(entry.claudeOAuthAccount, #"{"accountUuid":"personal"}"#)
    }

    func testCodexTokenRotationPersistsBackToTheSameSnapshot() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "codex-default-home", family: "codex")
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(
                credential: #"{"tokens":{"access_token":"old-token","refresh_token":"refresh","account_id":"personal"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        let store = CodexAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        )
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.auth.tokens?.accessToken = "new-token"

        try store.save(state)
        let entry = try XCTUnwrap(vault.load(profile: profile))
        XCTAssertEqual(CodexAuthStore.parseAuth(entry.credential)?.tokens?.accessToken, "new-token")
    }

    func testRemovingAnAccountDeletesItsCredentialSnapshot() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "codex-work", family: "codex")
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(
                credential: #"{"tokens":{"access_token":"work-token","account_id":"work"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )

        try AccountCredentialSnapshotRemover(keychain: keychain).remove(profile: profile)

        XCTAssertNil(try vault.load(profile: profile))
    }

    private func profile(id: String, family: String) -> AccountProfile {
        AccountProfile(
            id: id,
            family: family,
            label: "default",
            identityKey: "personal",
            createdAt: .distantPast
        )
    }
}

private final class SnapshotUsageKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String] = [:]
    var currentUserValues: [String: String] = [:]

    func readGenericPassword(service: String) throws -> String? { values[service] }
    func writeGenericPassword(service: String, value: String) throws { values[service] = value }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { currentUserValues[service] }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        currentUserValues[service] = value
    }
    func deleteGenericPassword(service: String) throws {
        values.removeValue(forKey: service)
        currentUserValues.removeValue(forKey: service)
    }
}
