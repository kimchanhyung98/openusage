import XCTest
@testable import OpenUsage

@MainActor
final class AccountPendingReSignInTests: XCTestCase {
    func testInteractivePendingRecoveryPreservesTheCompletedWorkspaceLogin() async throws {
        for (pendingIdentity, snapshotWritten) in [("previous", false), ("previous", true), ("interrupted", true)] {
            let fixture = try Fixture()
            fixture.store.setPreferred(family: "codex", profileID: fixture.profile.id)
            let previous = AccountCredentialVault.Entry(
                credential: #"{"tokens":{"access_token":"previous-token","account_id":"previous"}}"#,
                claudeOAuthAccount: nil
            )
            try fixture.switcher.saveSnapshot(previous, for: fixture.profile)
            try fixture.switcher.applySharedAuthentication(previous, family: "codex")
            let interrupted = AccountCredentialVault.Entry(
                credential: #"{"tokens":{"access_token":"old","account_id":"\#(pendingIdentity)"}}"#,
                claudeOAuthAccount: nil
            )
            _ = try fixture.store.beginIdentityReplacement(
                profileID: fixture.profile.id, with: pendingIdentity, replacesSharedAuthentication: true,
                replacementSnapshotDigest: interrupted.snapshotDigest(),
                originalSharedAuthenticationDigest: fixture.switcher.credentialArtifacts.authenticationDigest(
                    of: fixture.switcher.credentialArtifacts.capture(family: "codex")
                )
            )
            if snapshotWritten { try fixture.switcher.saveSnapshot(interrupted, for: fixture.profile) }
            try fixture.stageLogin()

            let recovered = try await fixture.importer.completeReSignInAfterLogin(
                profileID: fixture.profile.id, in: fixture.store
            )

            XCTAssertEqual(recovered.identityKey, fixture.replacementIdentity)
            XCTAssertEqual(try fixture.importer.readWorkspaceCredential(
                family: "codex", profileID: fixture.profile.id
            )?.entry, fixture.replacement)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), fixture.replacement)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.replacement)
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
            XCTAssertFalse(fixture.store.isAuthenticationMutationInProgress)
        }
    }

    func testInteractiveSignInDoesNotConsumeAnotherProfilesPendingRecovery() async throws {
        let fixture = try Fixture()
        let other = try fixture.store.add(family: "codex", label: "Other", identityKey: "other")
        let pending = try fixture.store.beginIdentityReplacement(
            profileID: other.id, with: "interrupted", replacesSharedAuthentication: false
        )
        try fixture.stageLogin()

        do {
            _ = try await fixture.importer.completeReSignInAfterLogin(
                profileID: fixture.profile.id, in: fixture.store
            )
            XCTFail("Another profile's pending replacement must block sign-in")
        } catch AccountIdentityReplacementError.pendingTransaction {
        }

        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), pending)
        XCTAssertNil(try fixture.switcher.loadSnapshot(for: fixture.profile))
        XCTAssertEqual(try fixture.importer.readWorkspaceCredential(
            family: "codex", profileID: fixture.profile.id
        )?.entry, fixture.replacement)
        XCTAssertFalse(fixture.store.isAuthenticationMutationInProgress)
    }

    func testPendingRecoveryDoesNotOverwriteTheCompletedWorkspaceLogin() throws {
        let fixture = try Fixture()
        let pending = try fixture.store.beginIdentityReplacement(
            profileID: fixture.profile.id, with: "interrupted", replacesSharedAuthentication: true
        )
        try fixture.switcher.saveSnapshot(
            .init(credential: #"{"tokens":{"access_token":"old","account_id":"interrupted"}}"#,
                  claudeOAuthAccount: nil), for: fixture.profile
        )
        try fixture.stageLogin()

        let recovered = try fixture.importer.completeReSignIn(
            profileID: fixture.profile.id, in: fixture.store, isActive: true
        )

        XCTAssertNotEqual(recovered.identityKey, pending.replacementIdentityKey)
        XCTAssertEqual(recovered.identityKey, fixture.replacementIdentity)
        XCTAssertEqual(try fixture.importer.readWorkspaceCredential(
            family: "codex", profileID: fixture.profile.id
        )?.entry, fixture.replacement)
    }

    func testAnotherProfilesPendingRecoveryIsNotConsumedBySignIn() throws {
        let fixture = try Fixture()
        let other = try fixture.store.add(family: "codex", label: "Other", identityKey: "other")
        let pending = try fixture.store.beginIdentityReplacement(
            profileID: other.id, with: "interrupted", replacesSharedAuthentication: false
        )
        try fixture.stageLogin()

        XCTAssertThrowsError(try fixture.importer.completeReSignIn(
            profileID: fixture.profile.id, in: fixture.store, isActive: false
        )) { error in
            guard case AccountIdentityReplacementError.pendingTransaction = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), pending)
        XCTAssertNil(try fixture.switcher.loadSnapshot(for: fixture.profile))
    }

    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let store: AccountProfilesStore
        let profile: AccountProfile
        let switcher: AccountCredentialSwitcher
        let importer: AccountCredentialImporter
        let replacement = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"fresh","account_id":"new"}}"#,
            claudeOAuthAccount: nil
        )
        let replacementIdentity = "new"

        @MainActor init() throws {
            suite = "AccountPendingReSignInTests-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
            let keychain = ServiceKeychain()
            store = AccountProfilesStore(defaults: defaults)
            profile = try store.add(family: "codex", label: "Personal", identityKey: "previous")
            switcher = AccountCredentialSwitcher(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
            importer = AccountCredentialImporter(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
        }

        func stageLogin() throws { try switcher.writeWorkspaceAuthentication(replacement, for: profile) }

        deinit {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
