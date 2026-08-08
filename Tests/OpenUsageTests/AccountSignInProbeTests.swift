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

    // MARK: - Fixtures

    private func makeProbe(keychain: KeychainAccessing) -> AccountSignInProbe {
        AccountSignInProbe(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
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
