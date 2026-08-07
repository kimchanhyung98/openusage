import XCTest
@testable import OpenUsage

/// **Sign In Again** and the no-default-login Add flow: an official (fake) CLI login lands in the
/// pinned home, and the importer registers or refreshes only same-account credentials.
@MainActor
final class AccountReSignInTests: XCTestCase {
    private var root: URL!
    private var keychain: ServiceKeychain!
    private var workspace: AccountSignInWorkspace!
    private var importer: AccountCredentialImporter!
    private var switcher: AccountCredentialSwitcher!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountReSignInTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        keychain = ServiceKeychain()
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        importer = AccountCredentialImporter(
            keychain: keychain,
            environment: FakeEnvironment([:]),
            homeDirectory: root,
            workspace: workspace
        )
        switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: FakeEnvironment([:]),
            homeDirectory: root,
            workspace: workspace
        )
        addTeardownBlock { [root] in
            try? FileManager.default.removeItem(at: root!)
        }
    }

    // MARK: - Sign In Again

    func testReSignInWithTheSameIdentityReplacesTheSnapshotAndRefreshesTheActiveHome() throws {
        let profile = AccountProfile(
            id: "profile-a",
            family: "codex",
            label: "Personal",
            identityKey: "acct-a",
            createdAt: .distantPast
        )
        try switcher.saveSnapshot(codexEntry(token: "old-token", accountID: "acct-a"), for: profile)
        let workspaceDir = try workspace.prepare(family: "codex", profileID: profile.id)
        try Data(codexAuth(token: "fresh-token", accountID: "acct-a").utf8)
            .write(to: workspaceDir.appendingPathComponent("auth.json"))

        try importer.completeReSignIn(for: profile, isActive: true)

        let snapshot = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        XCTAssertEqual(CodexAuthStore.parseAuth(snapshot.credential)?.tokens?.accessToken, "fresh-token")
        let sharedAuth = try String(
            contentsOf: root.appendingPathComponent(".codex/auth.json"),
            encoding: .utf8
        )
        XCTAssertEqual(CodexAuthStore.parseAuth(sharedAuth)?.tokens?.accessToken, "fresh-token")
    }

    func testReSignInWithAnInactiveProfileLeavesTheSharedHomeAlone() throws {
        let profile = AccountProfile(
            id: "profile-a",
            family: "codex",
            label: "Personal",
            identityKey: "acct-a",
            createdAt: .distantPast
        )
        try switcher.saveSnapshot(codexEntry(token: "old-token", accountID: "acct-a"), for: profile)
        let workspaceDir = try workspace.prepare(family: "codex", profileID: profile.id)
        try Data(codexAuth(token: "fresh-token", accountID: "acct-a").utf8)
            .write(to: workspaceDir.appendingPathComponent("auth.json"))

        try importer.completeReSignIn(for: profile, isActive: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/auth.json").path))
    }

    func testReSignInWithADifferentIdentityFailsAndRestoresTheWorkspace() throws {
        let profile = AccountProfile(
            id: "profile-a",
            family: "codex",
            label: "Personal",
            identityKey: "acct-a",
            createdAt: .distantPast
        )
        try switcher.saveSnapshot(codexEntry(token: "own-token", accountID: "acct-a"), for: profile)
        let workspaceDir = try workspace.prepare(family: "codex", profileID: profile.id)
        try Data(codexAuth(token: "other-token", accountID: "acct-b").utf8)
            .write(to: workspaceDir.appendingPathComponent("auth.json"))

        XCTAssertThrowsError(try importer.completeReSignIn(for: profile, isActive: true)) {
            XCTAssertEqual(
                $0 as? AccountCredentialImporter.ImportError,
                .differentAccount(profileLabel: "Personal")
            )
        }

        // The snapshot keeps the profile's own account, and the workspace was restored to it.
        let snapshot = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        XCTAssertEqual(CodexAuthStore.parseAuth(snapshot.credential)?.tokens?.accessToken, "own-token")
        let workspaceAuth = try String(
            contentsOf: workspaceDir.appendingPathComponent("auth.json"),
            encoding: .utf8
        )
        XCTAssertEqual(CodexAuthStore.parseAuth(workspaceAuth)?.tokens?.accountID, "acct-a")
    }

    // MARK: - Fake official CLI login → automatic import

    func testFakeCodexCLILoginIntoTheSharedHomeThenAutomaticImport() async throws {
        let binDir = root.appendingPathComponent("bin")
        try writeFakeCLI(
            named: "codex",
            in: binDir,
            script: """
            #!/bin/sh
            mkdir -p "$CODEX_HOME"
            printf '%s' '\(codexAuth(token: "login-token", accountID: "acct-new"))' > "$CODEX_HOME/auth.json"
            """
        )
        let sharedHome = root.appendingPathComponent(".codex").path

        let code = try await AccountSignInLauncher().runLogin(
            family: "codex",
            home: sharedHome,
            baseEnvironment: ["PATH": "\(binDir.path):/usr/bin:/bin"],
            usesLoginShellPATH: false
        )
        XCTAssertEqual(code, 0)

        let suite = "AccountReSignInTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try XCTUnwrap(importer.importDefaultAccount(family: "codex", into: store))

        XCTAssertEqual(profile.label, "default")
        XCTAssertEqual(profile.identityKey, "acct-new")
        XCTAssertEqual(store.preferredProfileID(family: "codex"), profile.id)
        XCTAssertNotNil(try switcher.loadSnapshot(for: profile))
    }

    func testFakeClaudeCLILoginIntoAWorkspaceThenRegistration() async throws {
        let binDir = root.appendingPathComponent("bin")
        try writeFakeCLI(
            named: "claude",
            in: binDir,
            script: """
            #!/bin/sh
            mkdir -p "$CLAUDE_CONFIG_DIR"
            printf '%s' '{"claudeAiOauth":{"accessToken":"login-token"}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
            printf '%s' '{"oauthAccount":{"accountUuid":"acct-new","organizationUuid":"org-new","emailAddress":"new@example.com"}}' > "$CLAUDE_CONFIG_DIR/.claude.json"
            """
        )
        let profileID = UUID().uuidString
        let home = try workspace.prepare(family: "claude", profileID: profileID)

        let code = try await AccountSignInLauncher().runLogin(
            family: "claude",
            home: home.path,
            baseEnvironment: ["PATH": "\(binDir.path):/usr/bin:/bin"],
            usesLoginShellPATH: false
        )
        XCTAssertEqual(code, 0)

        let credential = try XCTUnwrap(
            importer.readWorkspaceCredential(family: "claude", profileID: profileID)
        )
        XCTAssertEqual(credential.identityKey, "acct-new|org-new")

        let suite = "AccountReSignInTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try importer.register(
            credential,
            family: "claude",
            label: credential.label ?? "Account",
            id: profileID,
            into: store
        )
        XCTAssertEqual(profile.id, profileID)
        XCTAssertEqual(profile.label, "new@example.com")
    }

    // MARK: - Fixtures

    private func writeFakeCLI(named name: String, in directory: URL, script: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func codexAuth(token: String, accountID: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }

    private func codexEntry(token: String, accountID: String) -> AccountCredentialVault.Entry {
        AccountCredentialVault.Entry(
            credential: codexAuth(token: token, accountID: accountID),
            claudeOAuthAccount: nil
        )
    }
}
