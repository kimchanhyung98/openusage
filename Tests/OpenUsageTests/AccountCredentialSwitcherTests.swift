import XCTest
@testable import OpenUsage

final class AccountCredentialSwitcherTests: XCTestCase {
    // MARK: - Claude

    func testClaudeSwitchReplacesAuthenticationAndPreservesSharedState() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        let sharedHome = fixture.home.appendingPathComponent(".claude")
        let sessionFile = sharedHome.appendingPathComponent("projects/session.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("session-data".utf8).write(to: sessionFile)
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        // authentication만 이동: credential 파일, 양쪽 keychain service, 두 state 파일의 `oauthAccount` 키
        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent(".credentials.json")),
            claudeCredential(token: "token-b")
        )
        XCTAssertEqual(
            fixture.keychain.currentUserValues[baseClaudeService()],
            claudeCredential(token: "token-b")
        )
        XCTAssertEqual(
            fixture.keychain.currentUserValues[scopedClaudeService(home: sharedHome.path)],
            claudeCredential(token: "token-b")
        )
        let defaultState = try state(at: fixture.home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(defaultState["memory"] as? String, "keep")
        XCTAssertEqual(defaultState["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual((defaultState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-b")
        let localState = try state(at: sharedHome.appendingPathComponent(".claude.json"))
        XCTAssertEqual((localState["projects"] as? [String: Any])?.count, 1)
        XCTAssertEqual((localState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-b")
        XCTAssertEqual(try text(sessionFile), "session-data")

        // 떠나는 account의 live credential이 snapshot·workspace에 보존
        let preserved = try XCTUnwrap(fixture.vault.load(profile: personal))
        XCTAssertEqual(preserved.credential, claudeCredential(token: "token-a"))
        let personalWorkspace = try fixture.workspace.directory(family: "claude", profileID: personal.id)
        XCTAssertEqual(
            try text(personalWorkspace.appendingPathComponent(".credentials.json")),
            claudeCredential(token: "token-a")
        )
    }

    func testClaudeRoundTripRestoresTheFirstAccountWithoutRelogin() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)
        try fixture.switcher.switchAuthentication(to: personal, from: work)

        let sharedHome = fixture.home.appendingPathComponent(".claude")
        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent(".credentials.json")),
            claudeCredential(token: "token-a")
        )
        let defaultState = try state(at: fixture.home.appendingPathComponent(".claude.json"))
        XCTAssertEqual((defaultState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-a")
        // 중간에 활성이던 account의 credential 생존
        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: work)).credential,
            claudeCredential(token: "token-b")
        )
    }

    func testClaudeSwitchPreservesRotatedCredentialForTheActiveAccount() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        // snapshot은 stale, shared home은 동일 account의 더 새 token으로 rotate된 상태
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-a-old"), claudeOAuthAccount: claudeAccount("a")),
            profile: personal
        )
        try seedClaudeSharedHome(fixture, token: "token-a-new", account: claudeAccount("a"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: personal)).credential,
            claudeCredential(token: "token-a-new")
        )
        let workspaceCredentials = try fixture.workspace
            .directory(family: "claude", profileID: personal.id)
            .appendingPathComponent(".credentials.json")
        XCTAssertEqual(try text(workspaceCredentials), claudeCredential(token: "token-a-new"))

        try fixture.switcher.switchAuthentication(to: personal, from: work)
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a-new")
        )
    }

    func testSharedIdentityMismatchSkipsPreservationAndKeepsTheProfileSnapshot() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-a-old"), claudeOAuthAccount: claudeAccount("a")),
            profile: personal
        )
        // OpenUsage 외부에서 shared home이 제3의 account로 로그인된 상태
        try seedClaudeSharedHome(fixture, token: "token-c", account: claudeAccount("c"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        // 외부 credential이 떠나는 profile의 snapshot에 유입 금지
        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: personal)).credential,
            claudeCredential(token: "token-a-old")
        )
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-b")
        )
    }

    func testMissingSnapshotFailsWithoutTouchingTheSharedHome() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: personal)) { error in
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .missingSnapshot("Work"))
        }
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a")
        )
    }

    func testSnapshotIdentityMismatchFailsWithoutTouchingTheSharedHome() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        // snapshot 부패: 다른 account의 credential 보유
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-c"), claudeOAuthAccount: claudeAccount("c")),
            profile: work
        )

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: personal)) { error in
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .snapshotIdentityMismatch("Work"))
        }
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a")
        )
    }

    func testReselectingTheActiveProfileMakesNoWrites() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        let credentialsBefore = try text(fixture.home.appendingPathComponent(".claude/.credentials.json"))
        fixture.keychain.writeCount = 0

        try fixture.switcher.switchAuthentication(to: personal, from: personal)

        XCTAssertEqual(fixture.keychain.writeCount, 0)
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            credentialsBefore
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try fixture.workspace.directory(family: "claude", profileID: personal.id)).path
            )
        )
    }

    func testKeychainWriteFailureRollsBackTheSharedCredentialFile() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )
        fixture.keychain.failingCurrentUserServices = [baseClaudeService()]

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: personal))

        // apply가 credential 파일에 도달하지 않고 이전 account 유지
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a")
        )
        let defaultState = try state(at: fixture.home.appendingPathComponent(".claude.json"))
        XCTAssertEqual((defaultState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-a")
    }

    // MARK: - Codex

    func testCodexSwitchReplacesOnlyAuthJSONAndPreservesSharedConfig() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "codex", label: "Personal", identityKey: "acct-a")
        let work = profile(id: "profile-b", family: "codex", label: "Work", identityKey: "acct-b")
        let sharedHome = fixture.home.appendingPathComponent(".codex")
        try seedCodexSharedHome(fixture, accountID: "acct-a", token: "token-a")
        try Data("model = \"o3\"".utf8).write(to: sharedHome.appendingPathComponent("config.toml"))
        let sessionFile = sharedHome.appendingPathComponent("sessions/rollout.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("rollout-data".utf8).write(to: sessionFile)
        try fixture.vault.save(
            .init(credential: codexAuth(accountID: "acct-b", token: "token-b"), claudeOAuthAccount: nil),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent("auth.json")),
            codexAuth(accountID: "acct-b", token: "token-b")
        )
        XCTAssertEqual(try text(sharedHome.appendingPathComponent("config.toml")), "model = \"o3\"")
        XCTAssertEqual(try text(sessionFile), "rollout-data")

        let preserved = try XCTUnwrap(fixture.vault.load(profile: personal))
        XCTAssertEqual(preserved.credential, codexAuth(accountID: "acct-a", token: "token-a"))
        let workspaceAuth = try fixture.workspace
            .directory(family: "codex", profileID: personal.id)
            .appendingPathComponent("auth.json")
        XCTAssertEqual(try text(workspaceAuth), codexAuth(accountID: "acct-a", token: "token-a"))
    }

    func testCodexIdentityMismatchNeverOverwritesTheLeavingSnapshot() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "codex", label: "Personal", identityKey: "acct-a")
        let work = profile(id: "profile-b", family: "codex", label: "Work", identityKey: "acct-b")
        try fixture.vault.save(
            .init(credential: codexAuth(accountID: "acct-a", token: "token-a-old"), claudeOAuthAccount: nil),
            profile: personal
        )
        try seedCodexSharedHome(fixture, accountID: "acct-c", token: "token-c")
        try fixture.vault.save(
            .init(credential: codexAuth(accountID: "acct-b", token: "token-b"), claudeOAuthAccount: nil),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: personal)).credential,
            codexAuth(accountID: "acct-a", token: "token-a-old")
        )
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".codex/auth.json")),
            codexAuth(accountID: "acct-b", token: "token-b")
        )
    }

    // MARK: - Fixtures

    private struct Fixture {
        let home: URL
        let keychain: CountingKeychain
        let workspace: AccountSignInWorkspace
        let switcher: AccountCredentialSwitcher
        let vault: AccountCredentialVault
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountCredentialSwitcher.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.resolvingSymlinksInPath().standardizedFileURL
        let keychain = CountingKeychain()
        let workspace = AccountSignInWorkspace(
            baseDirectory: home.appendingPathComponent("AppSupport/OpenUsage/AccountSignIn")
        )
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: FakeEnvironment([:]),
            homeDirectory: home,
            workspace: workspace
        )
        return Fixture(
            home: home,
            keychain: keychain,
            workspace: workspace,
            switcher: switcher,
            vault: AccountCredentialVault(keychain: keychain)
        )
    }

    private func profile(id: String, family: String, label: String, identityKey: String) -> AccountProfile {
        AccountProfile(id: id, family: family, label: label, identityKey: identityKey, createdAt: .distantPast)
    }

    private func claudeCredential(token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(token)"}}"#
    }

    private func claudeAccount(_ suffix: String) -> String {
        #"{"accountUuid":"acct-\#(suffix)","emailAddress":"\#(suffix)@example.com","organizationName":"Org","organizationUuid":"org-\#(suffix)"}"#
    }

    private func codexAuth(accountID: String, token: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }

    /// 로그인된 shared Claude home — 보존 관측용으로 추가 키 포함
    private func seedClaudeSharedHome(_ fixture: Fixture, token: String, account: String) throws {
        let sharedHome = fixture.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        try Data(claudeCredential(token: token).utf8)
            .write(to: sharedHome.appendingPathComponent(".credentials.json"))
        fixture.keychain.currentUserValues[baseClaudeService()] = claudeCredential(token: token)
        let accountObject = try JSONSerialization.jsonObject(with: Data(account.utf8))
        let defaultState: [String: Any] = [
            "memory": "keep",
            "hasCompletedOnboarding": true,
            "oauthAccount": accountObject,
        ]
        try JSONSerialization.data(withJSONObject: defaultState, options: [.sortedKeys])
            .write(to: fixture.home.appendingPathComponent(".claude.json"))
        let localState: [String: Any] = [
            "projects": ["/tmp/project": ["allowedTools": [String]()]],
            "oauthAccount": accountObject,
        ]
        try JSONSerialization.data(withJSONObject: localState, options: [.sortedKeys])
            .write(to: sharedHome.appendingPathComponent(".claude.json"))
    }

    private func seedCodexSharedHome(_ fixture: Fixture, accountID: String, token: String) throws {
        let sharedHome = fixture.home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: accountID, token: token).utf8)
            .write(to: sharedHome.appendingPathComponent("auth.json"))
    }

    private func baseClaudeService() -> String {
        ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
    }

    private func scopedClaudeService(home: String) -> String {
        ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: home, environment: FakeEnvironment([:]))
    }

    private func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func state(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// service 단위 keychain double — switcher가 service 주소 기반이라 service를 모르는 `FakeKeychain`으로 대체 불가
private final class CountingKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String] = [:]
    var currentUserValues: [String: String] = [:]
    var writeCount = 0
    var failingCurrentUserServices: Set<String> = []

    struct WriteFailure: Error {}

    func readGenericPassword(service: String) throws -> String? { values[service] }

    func writeGenericPassword(service: String, value: String) throws {
        writeCount += 1
        values[service] = value
    }

    func deleteGenericPassword(service: String) throws {
        values.removeValue(forKey: service)
        currentUserValues.removeValue(forKey: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? { currentUserValues[service] }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        guard !failingCurrentUserServices.contains(service) else { throw WriteFailure() }
        writeCount += 1
        currentUserValues[service] = value
    }
}
