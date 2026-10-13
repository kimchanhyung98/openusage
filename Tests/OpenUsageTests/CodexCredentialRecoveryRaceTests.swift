import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialRecoveryRaceTests: XCTestCase {
    func testStartupRecoveryDefersWhenTheSnapshotRotatesDuringItsRead() async throws {
        let suite = "CodexRecoveryRace-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: home)
        }
        let profiles = AccountProfilesStore(defaults: defaults)
        let profile = try profiles.add(family: "codex", label: "Saved", identityKey: "A", id: "saved")
        let keychain = RecoveryRaceKeychain()
        let workspace = AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        let switcher = AccountCredentialSwitcher(keychain: keychain, environment: FakeEnvironment(),
                                                 homeDirectory: home, workspace: workspace)
        let importer = AccountCredentialImporter(keychain: keychain, environment: FakeEnvironment(),
                                                 homeDirectory: home, workspace: workspace)
        let previous = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"previous-A","account_id":"A"}}"#
        )
        let replacement = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"old-B","refresh_token":"refresh-B","account_id":"B"}}"#
        )
        try switcher.applySharedAuthentication(previous, family: "codex")
        try switcher.saveSnapshot(replacement, for: profile)
        _ = try profiles.beginIdentityReplacement(profileID: profile.id, with: "B", replacesSharedAuthentication: true)
        let authStore = CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                      scope: .accountSnapshot(profileID: profile.id))
        var rotated = try XCTUnwrap(authStore.loadAccountSnapshot(profileID: profile.id))
        rotated.auth.tokens?.accessToken = "fresh-B"
        let rotatedState = rotated
        keychain.onNextRead = {
            XCTAssertFalse(Thread.isMainThread)
            _ = try authStore.save(rotatedState)
        }

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: profiles)

        XCTAssertEqual(result, .unchanged)
        XCTAssertNotNil(try profiles.pendingIdentityReplacement())
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), previous)
        XCTAssertEqual(try authStore.loadAccountSnapshot(profileID: profile.id)?.auth.tokens?.accessToken, "fresh-B")

        _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: profiles)

        XCTAssertNil(try profiles.pendingIdentityReplacement())
        XCTAssertEqual(profiles.profile(id: profile.id)?.identityKey, "b")
        let recovered = try XCTUnwrap(switcher.readSharedAuthentication(family: "codex"))
        XCTAssertEqual(CodexAuthStore.parseAuth(recovered.credential)?.tokens?.accessToken, "fresh-B")
    }
}

private final class RecoveryRaceKeychain: KeychainAccessing, @unchecked Sendable {
    private let base = ServiceKeychain()
    var onNextRead: (@Sendable () throws -> Void)?

    func readGenericPassword(service: String) throws -> String? {
        try base.readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        let captured = try base.readGenericPasswordForCurrentUser(service: service)
        let hook = onNextRead
        onNextRead = nil
        try hook?()
        return captured
    }

    func writeGenericPassword(service: String, value: String) throws {
        try base.writeGenericPassword(service: service, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try base.writeGenericPasswordForCurrentUser(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try base.deleteGenericPassword(service: service)
    }
}
