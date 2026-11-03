import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexReSignInIsolationTests: XCTestCase {
    private var root: URL!
    private var workspace: AccountSignInWorkspace!
    private var switcher: AccountCredentialSwitcher!
    private var importer: AccountCredentialImporter!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: AccountProfilesStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        let keychain = ServiceKeychain()
        switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        suite = "CodexReSignInIsolationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = AccountProfilesStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    func testSwitchingAwayCannotReplaceACompletedLoginWithThePreviousAccount() async throws {
        let previous = entry(token: "previous-wv", account: "wv-account")
        let ad = try addProfile(label: "ad", entry: previous)
        let wv = try addProfile(label: "wv", entry: entry(token: "other-wv", account: "wv-account"))
        try switcher.applySharedAuthentication(previous, family: "codex")
        let signIn = try workspace.prepareReauthentication(family: "codex", profileID: ad.id)
        let fresh = entry(token: "fresh-admin", account: "admin-account")

        let code = try await runLogin(home: signIn.directory, script: """
        printf '%s' '\(fresh.credential)' > "$CODEX_HOME/auth.json"
        """)
        XCTAssertEqual(code, 0)

        // 로그인 프로세스 종료와 UI의 결과 저장 사이에 다른 화면의 전환 완료.
        try switcher.switchAuthentication(to: wv, from: ad)
        store.setPreferred(family: "codex", profileID: wv.id)
        let restored = try importer.completeReSignIn(
            profileID: ad.id, in: store, isActive: false, signInProfileID: signIn.profileID
        )

        XCTAssertEqual(restored.identityKey, "admin-account")
        XCTAssertEqual(try switcher.loadSnapshot(for: restored), fresh)
        XCTAssertEqual(store.preferredProfileID(family: "codex"), wv.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), try switcher.loadSnapshot(for: wv))
        try importer.removeSignInWorkspace(family: "codex", profileID: signIn.profileID)
        XCTAssertEqual(try switcher.loadSnapshot(for: restored), fresh)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: restored.id)?.entry, fresh)
    }

    func testFailedLoginCannotRevokeAnExistingSnapshotThroughItsWorkspaceCopy() async throws {
        let original = entry(token: "saved-admin", account: "admin-account")
        let ad = try addProfile(label: "ad", entry: original)
        try switcher.applySharedAuthentication(original, family: "codex")
        let signIn = try workspace.prepareReauthentication(family: "codex", profileID: ad.id)

        // Codex 0.166의 로그인 시작 시 기존 인증 폐기를 재현하는 로컬 CLI.
        let code = try await runLogin(home: signIn.directory, script: """
        if [ -f "$CODEX_HOME/auth.json" ]; then
            printf revoked > "$CODEX_HOME/revoked"
            rm "$CODEX_HOME/auth.json"
        fi
        exit 1
        """)

        XCTAssertEqual(code, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: signIn.directory.appendingPathComponent("revoked").path))
        XCTAssertEqual(try switcher.loadSnapshot(for: ad), original)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), original)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: ad.id)?.entry, original)
        try importer.removeSignInWorkspace(family: "codex", profileID: signIn.profileID)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: ad.id)?.entry, original)
    }

    func testASecondLoginCannotReadThePreviousAttemptsCredential() async throws {
        let original = entry(token: "saved-admin", account: "admin-account")
        let ad = try addProfile(label: "ad", entry: original)
        let first = try workspace.prepareReauthentication(family: "codex", profileID: ad.id)
        let second = try workspace.prepareReauthentication(family: "codex", profileID: ad.id)
        let stale = entry(token: "late-wv", account: "wv-account")
        try workspace.writePrivateFile(stale.credential, to: first.directory.appendingPathComponent("auth.json"))

        XCTAssertNil(try importer.readWorkspaceCredential(family: "codex", profileID: second.profileID))
        XCTAssertEqual(try switcher.loadSnapshot(for: ad), original)
    }

    private func addProfile(label: String, entry: AccountCredentialVault.Entry) throws -> AccountProfile {
        let identity = try XCTUnwrap(switcher.identity(of: entry, family: "codex")?.identityKey)
        let profile = try store.add(family: "codex", label: label, identityKey: identity)
        try switcher.saveSnapshot(entry, for: profile)
        try switcher.writeWorkspaceAuthentication(entry, for: profile)
        return profile
    }

    private func entry(token: String, account: String) -> AccountCredentialVault.Entry {
        .init(
            credential: #"{"tokens":{"access_token":"\#(token)","refresh_token":"refresh-\#(token)","account_id":"\#(account)"}}"#,
            claudeOAuthAccount: nil
        )
    }

    private func runLogin(home: URL, script: String) async throws -> Int32 {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return try await AccountSignInLauncher().runLogin(
            family: "codex", home: home.path, baseEnvironment: ["PATH": "\(bin.path):/usr/bin:/bin"],
            usesLoginShellPATH: false
        )
    }
}
