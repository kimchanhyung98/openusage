import XCTest
@testable import OpenUsage

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
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let profile = try store.add(family: "codex", label: "alpha", identityKey: "acct-a", id: "profile-a")
        try switcher.saveSnapshot(codexEntry(token: "old-token", accountID: "acct-a"), for: profile)
        let workspaceDir = try workspace.prepare(family: "codex", profileID: profile.id)
        try Data(codexAuth(token: "fresh-token", accountID: "acct-a").utf8)
            .write(to: workspaceDir.appendingPathComponent("auth.json"))

        try importer.completeReSignIn(profileID: profile.id, in: store, isActive: true)

        let snapshot = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        XCTAssertEqual(CodexAuthStore.parseAuth(snapshot.credential)?.tokens?.accessToken, "fresh-token")
        let sharedAuth = try String(
            contentsOf: root.appendingPathComponent(".codex/auth.json"),
            encoding: .utf8
        )
        XCTAssertEqual(CodexAuthStore.parseAuth(sharedAuth)?.tokens?.accessToken, "fresh-token")
    }

    func testReSignInWithAnInactiveProfileLeavesTheSharedHomeAlone() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let profile = try store.add(family: "codex", label: "alpha", identityKey: "acct-a", id: "profile-a")
        try switcher.saveSnapshot(codexEntry(token: "old-token", accountID: "acct-a"), for: profile)
        let workspaceDir = try workspace.prepare(family: "codex", profileID: profile.id)
        try Data(codexAuth(token: "fresh-token", accountID: "acct-a").utf8)
            .write(to: workspaceDir.appendingPathComponent("auth.json"))

        try importer.completeReSignIn(profileID: profile.id, in: store, isActive: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/auth.json").path))
    }

    func testReSignInAfterRenameReplacesIdentityAndPreservesTheNamedProfile() throws {
        let suite = "AccountReSignInTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try store.add(
            family: "codex",
            label: "beta",
            identityKey: "acct-a",
            id: "profile-a"
        )
        try store.rename(profileID: profile.id, to: "gamma")
        try switcher.saveSnapshot(codexEntry(token: "own-token", accountID: "acct-a"), for: profile)
        let workspaceDir = try workspace.prepare(family: "codex", profileID: profile.id)
        try Data(codexAuth(token: "other-token", accountID: "acct-b").utf8)
            .write(to: workspaceDir.appendingPathComponent("auth.json"))

        let rebound = try importer.completeReSignIn(
            profileID: profile.id,
            in: store,
            isActive: true
        )

        XCTAssertEqual(rebound.id, profile.id)
        XCTAssertEqual(rebound.label, "gamma")
        XCTAssertEqual(rebound.identityKey, "acct-b")
        XCTAssertEqual(store.preferredProfileID(family: "codex"), profile.id)
        let snapshot = try XCTUnwrap(switcher.loadSnapshot(for: rebound))
        XCTAssertEqual(CodexAuthStore.parseAuth(snapshot.credential)?.tokens?.accessToken, "other-token")
        let workspaceAuth = try String(
            contentsOf: workspaceDir.appendingPathComponent("auth.json"),
            encoding: .utf8
        )
        XCTAssertEqual(CodexAuthStore.parseAuth(workspaceAuth)?.tokens?.accountID, "acct-b")
        let sharedAuth = try String(
            contentsOf: root.appendingPathComponent(".codex/auth.json"),
            encoding: .utf8
        )
        XCTAssertEqual(CodexAuthStore.parseAuth(sharedAuth)?.tokens?.accountID, "acct-b")
    }

    func testClaudeReSignInFailureRestoresTheWorkspaceScopedCredential() throws {
        let failingKeychain = FailOnceServiceKeychain()
        let localImporter = AccountCredentialImporter(
            keychain: failingKeychain,
            environment: FakeEnvironment([:]),
            homeDirectory: root,
            workspace: workspace
        )
        let localSwitcher = AccountCredentialSwitcher(
            keychain: failingKeychain,
            environment: FakeEnvironment([:]),
            homeDirectory: root,
            workspace: workspace
        )
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let profile = try store.add(
            family: "claude",
            label: "alpha",
            identityKey: "acct-a|org-a",
            id: "profile-a"
        )
        let previous = claudeEntry(token: "token-a", account: "a")
        let replacement = claudeEntry(token: "token-b", account: "b")
        try localSwitcher.saveSnapshot(previous, for: profile)
        try localSwitcher.applySharedAuthentication(previous, family: "claude")
        try localSwitcher.writeWorkspaceAuthentication(replacement, for: profile)
        let workspaceHome = try workspace.directory(family: "claude", profileID: profile.id)
        failingKeychain.currentUserValues[
            ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: workspaceHome.path,
                environment: FakeEnvironment([:])
            )
        ] = replacement.credential
        failingKeychain.failNextCurrentUserWrite(
            service: ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
        )

        XCTAssertThrowsError(
            try localImporter.completeReSignIn(profileID: profile.id, in: store, isActive: true)
        )

        let restored = try XCTUnwrap(store.profile(id: profile.id))
        XCTAssertEqual(restored.identityKey, "acct-a|org-a")
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
        XCTAssertEqual(try localSwitcher.loadSnapshot(for: restored), previous)
        let workspaceCredential = try XCTUnwrap(
            localImporter.readWorkspaceCredential(family: "claude", profileID: profile.id)
        )
        XCTAssertEqual(workspaceCredential.entry, previous)
        XCTAssertEqual(
            try localSwitcher.readSharedAuthentication(family: "claude"),
            previous
        )
    }

    // MARK: - External reauthentication

    func testSharedClaudeReauthenticationRebindsOnlyTheSelectedNamedProfile() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let alpha = try store.add(
            family: "claude",
            label: "alpha",
            identityKey: "acct-a|org-a",
            id: "profile-alpha"
        )
        let beta = try store.add(
            family: "claude",
            label: "beta",
            identityKey: "acct-b|org-b",
            id: "profile-beta"
        )
        try switcher.saveSnapshot(claudeEntry(token: "token-a", account: "a"), for: alpha)
        try switcher.saveSnapshot(claudeEntry(token: "token-b-old", account: "b"), for: beta)
        try switcher.writeWorkspaceAuthentication(
            claudeEntry(token: "token-b-old", account: "b"),
            for: beta
        )
        try seedSharedClaudeLogin(token: "token-b-new", previousAccount: "a", account: "b")

        let result = try importer.reconcileSelectedClaudeSharedAuthentication(in: store)

        let rebound = try XCTUnwrap(store.profile(id: alpha.id))
        XCTAssertEqual(result, .updated(profileID: alpha.id))
        XCTAssertEqual(rebound.label, "alpha")
        XCTAssertEqual(rebound.identityKey, "acct-b|org-b")
        XCTAssertEqual(store.preferredProfileID(family: "claude"), alpha.id)
        XCTAssertEqual(store.profile(id: beta.id)?.identityKey, "acct-b|org-b")
        let reboundSnapshot = try XCTUnwrap(switcher.loadSnapshot(for: rebound))
        XCTAssertEqual(
            ClaudeAuthStore.parseCredentials(reboundSnapshot.credential)?.claudeAiOauth?.accessToken,
            "token-b-new"
        )
        let workspaceCredential = try String(
            contentsOf: (try workspace.directory(family: "claude", profileID: alpha.id))
                .appendingPathComponent(".credentials.json"),
            encoding: .utf8
        )
        XCTAssertEqual(
            ClaudeAuthStore.parseCredentials(workspaceCredential)?.claudeAiOauth?.accessToken,
            "token-b-new"
        )
        let normalizedShared = try XCTUnwrap(switcher.readSharedAuthentication(family: "claude"))
        XCTAssertEqual(
            switcher.identity(of: normalizedShared, family: "claude")?.identityKey,
            "acct-b|org-b"
        )
        XCTAssertEqual(
            AccountSignInProbe(
                environment: FakeEnvironment([:]),
                keychain: keychain,
                homeDirectory: { [root] in root! }
            ).state(for: rebound, isSelected: true),
            .ready(identityKey: "acct-b|org-b", label: nil)
        )

        try importer.removeAccount(beta, from: store)
        XCTAssertNil(store.profile(id: beta.id))
        XCTAssertEqual(store.preferredProfileID(family: "claude"), alpha.id)
    }

    func testIncompleteSharedClaudeLoginDoesNotCombineANewTokenWithThePreviousIdentity() throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let profile = try store.add(
            family: "claude",
            label: "alpha",
            identityKey: "acct-a|org-a",
            id: "profile-alpha"
        )
        let previous = claudeEntry(token: "token-a", account: "a")
        let incomplete = claudeEntry(token: "token-b", account: "b")
        try switcher.saveSnapshot(previous, for: profile)
        let sharedHome = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        keychain.currentUserValues[
            ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: sharedHome.path,
                environment: FakeEnvironment([:])
            )
        ] = incomplete.credential
        try Data(#"{"oauthAccount":\#(previous.claudeOAuthAccount!)}"#.utf8)
            .write(to: root.appendingPathComponent(".claude.json"))

        let result = try importer.reconcileSelectedClaudeSharedAuthentication(in: store)

        XCTAssertEqual(result, .noUsableAuthentication)
        XCTAssertEqual(store.profile(id: profile.id)?.identityKey, "acct-a|org-a")
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), previous)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try workspace.directory(family: "claude", profileID: profile.id)).path
            )
        )
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

    private func makeStore() -> (AccountProfilesStore, () -> Void) {
        let suite = "AccountReSignInTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AccountProfilesStore(defaults: defaults), {
            defaults.removePersistentDomain(forName: suite)
        })
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

    private func claudeEntry(token: String, account: String) -> AccountCredentialVault.Entry {
        AccountCredentialVault.Entry(
            credential: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
        )
    }

    private func seedSharedClaudeLogin(token: String, previousAccount: String, account: String) throws {
        let sharedHome = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        let entry = claudeEntry(token: token, account: account)
        keychain.currentUserValues[
            ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: sharedHome.path,
                environment: FakeEnvironment([:])
            )
        ] = entry.credential
        let previous = claudeEntry(token: "previous", account: previousAccount)
        try Data(#"{"oauthAccount":\#(previous.claudeOAuthAccount!)}"#.utf8)
            .write(to: root.appendingPathComponent(".claude.json"))
        try Data(#"{"oauthAccount":\#(entry.claudeOAuthAccount!)}"#.utf8)
            .write(to: sharedHome.appendingPathComponent(".claude.json"))
    }
}

private final class FailOnceServiceKeychain: KeychainAccessing, @unchecked Sendable {
    enum Failure: Error {
        case write
    }

    var values: [String: String] = [:]
    var currentUserValues: [String: String] = [:]
    private var failingCurrentUserService: String?

    func failNextCurrentUserWrite(service: String) {
        failingCurrentUserService = service
    }

    func readGenericPassword(service: String) throws -> String? {
        values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        values[service] = value
    }

    func deleteGenericPassword(service: String) throws {
        values.removeValue(forKey: service)
        currentUserValues.removeValue(forKey: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        currentUserValues[service]
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        if failingCurrentUserService == service {
            failingCurrentUserService = nil
            throw Failure.write
        }
        currentUserValues[service] = value
    }
}
