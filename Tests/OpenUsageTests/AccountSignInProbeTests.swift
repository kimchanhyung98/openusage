import XCTest
@testable import OpenUsage

final class AccountSignInProbeTests: XCTestCase {
    func testClaudeSnapshotProvingItsIdentityIsReady() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p1", family: "claude", identityKey: "acct-a|org-a")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"token-a"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","emailAddress":"a@example.com","organizationName":"Org A","organizationUuid":"org-a"}"#
            ),
            profile: profile
        )

        let state = makeProbe(keychain: keychain).state(for: profile)

        XCTAssertEqual(state, .ready(identityKey: "acct-a|org-a", label: "a@example.com (Org A)"))
    }

    func testCodexSnapshotProvingItsIdentityIsReady() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p2", family: "codex", identityKey: "acct-b")
        let idToken = fakeJWT(payload: ["email": "b@example.com"])
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"tokens":{"access_token":"token-b","account_id":"acct-b","id_token":"\#(idToken)"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )

        let state = makeProbe(keychain: keychain).state(for: profile)

        XCTAssertEqual(state, .ready(identityKey: "acct-b", label: "b@example.com"))
    }

    func testMissingSnapshotNeedsSignIn() {
        let profile = profile(id: "p3", family: "claude", identityKey: "acct-a|org-a")

        XCTAssertEqual(makeProbe(keychain: ServiceKeychain()).state(for: profile), .needsSignIn)
    }

    func testSnapshotReadFailureNeedsSignIn() {
        let profile = profile(id: "p-read-failure", family: "claude", identityKey: "acct-a|org-a")

        XCTAssertEqual(makeProbe(keychain: ThrowingProbeKeychain()).state(for: profile), .needsSignIn)
    }

    func testSnapshotForADifferentAccountNeedsSignIn() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p4", family: "codex", identityKey: "acct-b")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"tokens":{"access_token":"token-c","account_id":"acct-c"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )

        XCTAssertEqual(makeProbe(keychain: keychain).state(for: profile), .needsSignIn)
    }

    func testSnapshotWithoutAUsableTokenNeedsSignIn() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p5", family: "claude", identityKey: "acct-a|org-a")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":""}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","organizationUuid":"org-a"}"#
            ),
            profile: profile
        )

        XCTAssertEqual(makeProbe(keychain: keychain).state(for: profile), .needsSignIn)
    }

    func testExpiredClaudeSnapshotWithoutARefreshTokenNeedsSignIn() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p6", family: "claude", identityKey: "acct-a|org-a")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"expired-token","expiresAt":1}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","organizationUuid":"org-a"}"#
            ),
            profile: profile
        )

        XCTAssertEqual(makeProbe(keychain: keychain).state(for: profile), .needsSignIn)
    }

    func testExpiredClaudeSnapshotWithARefreshTokenRemainsReady() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p7", family: "claude", identityKey: "acct-a|org-a")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"expired-token","refreshToken":"refresh-token","expiresAt":1}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","organizationUuid":"org-a"}"#
            ),
            profile: profile
        )

        XCTAssertEqual(
            makeProbe(keychain: keychain).state(for: profile),
            .ready(identityKey: "acct-a|org-a", label: nil)
        )
    }

    func testSelectedClaudeSnapshotIsNotReadyWhenTheSharedHomeIsLoggedOut() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p8", family: "claude", identityKey: "acct-a|org-a")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"token-a"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","organizationUuid":"org-a"}"#
            ),
            profile: profile
        )
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountSignInProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"claudeAiOauth":{"accessToken":"stale-file-token"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/.credentials.json"))
        try Data(#"{"oauthAccount":{"accountUuid":"acct-a","organizationUuid":"org-a"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        try Data(#"{"oauthAccount":{"accountUuid":"acct-a","organizationUuid":"org-a"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/.claude.json"))
        keychain.currentUserValues[
            ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
        ] = #"{"claudeAiOauth":{"accessToken":"stale-base-token"}}"#

        let state = makeProbe(keychain: keychain, home: home).state(for: profile, isSelected: true)

        XCTAssertEqual(state, .needsSignIn)
    }

    func testSelectedClaudeAcceptsTheBaseLoginBeforeTheManagedHomeIsInitialized() throws {
        let keychain = ServiceKeychain()
        let profile = profile(id: "p9", family: "claude", identityKey: "acct-a|org-a")
        let credential = #"{"claudeAiOauth":{"accessToken":"token-a"}}"#
        let account = #"{"accountUuid":"acct-a","organizationUuid":"org-a"}"#
        try AccountCredentialVault(keychain: keychain).save(
            .init(credential: credential, claudeOAuthAccount: account),
            profile: profile
        )
        keychain.currentUserValues[
            ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
        ] = credential
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountSignInProbeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"oauthAccount":\#(account)}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))

        let state = makeProbe(keychain: keychain, home: home).state(for: profile, isSelected: true)

        XCTAssertEqual(state, .ready(identityKey: "acct-a|org-a", label: nil))
    }

    func testSelectedClaudeSharedHomeReadFailureNeedsSignIn() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountSignInProbeTests-\(UUID().uuidString)")
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home.appendingPathComponent(".claude").path,
            environment: FakeEnvironment([:])
        )
        let keychain = SharedReadThrowingProbeKeychain(failingService: scopedService)
        let profile = profile(id: "p-shared-read-failure", family: "claude", identityKey: "acct-a|org-a")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"token-a"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","organizationUuid":"org-a"}"#
            ),
            profile: profile
        )
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }

        let state = makeProbe(keychain: keychain, home: home).state(for: profile, isSelected: true)

        XCTAssertEqual(state, .needsSignIn)
    }

    // MARK: - Fixtures

    private func makeProbe(
        keychain: KeychainAccessing,
        home: URL = URL(fileURLWithPath: "/Users/dev")
    ) -> AccountSignInProbe {
        AccountSignInProbe(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            homeDirectory: { home }
        )
    }

    private func profile(id: String, family: String, identityKey: String) -> AccountProfile {
        AccountProfile(id: id, family: family, label: "Account", identityKey: identityKey, createdAt: .distantPast)
    }

    private func fakeJWT(payload: [String: Any]) -> String {
        func segment(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object)
            return data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(segment(["alg": "none"])).\(segment(payload)).sig"
    }
}

private struct ThrowingProbeKeychain: KeychainAccessing {
    private struct ReadFailure: Error {}

    func readGenericPassword(service: String) throws -> String? { throw ReadFailure() }
    func writeGenericPassword(service: String, value: String) throws {}
    func deleteGenericPassword(service: String) throws {}
}

private final class SharedReadThrowingProbeKeychain: KeychainAccessing, @unchecked Sendable {
    private struct ReadFailure: Error {}

    private var values: [String: String] = [:]
    private let failingService: String

    init(failingService: String) {
        self.failingService = failingService
    }

    func readGenericPassword(service: String) throws -> String? {
        values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        values[service] = value
    }

    func deleteGenericPassword(service: String) throws {
        values.removeValue(forKey: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        if service == failingService { throw ReadFailure() }
        return values[service]
    }
}
