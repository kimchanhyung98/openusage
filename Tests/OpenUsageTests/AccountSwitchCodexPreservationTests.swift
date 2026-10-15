import XCTest
@testable import OpenUsage

@MainActor
final class AccountSwitchCodexPreservationTests: XCTestCase {
    func testJournaledSwitchPreservesDepartedRotationAndClearsSelectedStaleMarkers() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        try fixture.switcher.switchAuthentication(to: fixture.target, in: fixture.store)

        try assertSwitched(fixture)
        let workspace = try fixture.workspace.directory(family: "codex", profileID: fixture.previous.id)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("auth.json"), encoding: .utf8),
            fixture.rotatedPrevious.credential
        )
    }

    func testInterruptedApplyRetainsDigestUntilSelectionAndPreservesRotatedSnapshots() async throws {
        for afterStartup in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let original = try fixture.switcher.credentialArtifacts.capture(family: "codex")
            let transaction = try AccountSwitchTransition(
                family: "codex", previousProfileID: fixture.previous.id,
                targetProfileID: fixture.target.id, targetIdentityKey: fixture.target.identityKey,
                targetSnapshotDigest: fixture.rotatedTarget.snapshotDigest(), original: original,
                applied: fixture.switcher.credentialArtifacts.applying(fixture.rotatedTarget, to: original)
            )
            try fixture.switcher.switchJournal.save(transaction)
            try fixture.switcher.applySharedAuthentication(fixture.rotatedTarget, family: "codex")
            XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.previous.id)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.target), fixture.rotatedTarget)

            if afterStartup {
                let recovered = try await fixture.switcher.recoverInterruptedSwitchAfterStartup(in: fixture.store)
                XCTAssertTrue(recovered)
            } else {
                XCTAssertTrue(try fixture.switcher.recoverInterruptedSwitch(in: fixture.store))
            }

            try assertSwitched(fixture)
        }
    }

    func testSameAccountSelectionDoesNotRecoverOrWriteAuthentication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        fixture.keychain.currentUserValues[AccountSwitchJournal.service] = "unreadable-journal"
        let keychainBefore = fixture.keychain.currentUserValues
        let sharedBefore = try fixture.switcher.credentialArtifacts.capture(family: "codex")
        let revision = AccountCredentialMutationLock.revision

        try fixture.switcher.switchAuthentication(to: fixture.previous, in: fixture.store)

        XCTAssertEqual(AccountCredentialMutationLock.revision, revision)
        XCTAssertEqual(fixture.keychain.currentUserValues, keychainBefore)
        XCTAssertEqual(try fixture.switcher.credentialArtifacts.capture(family: "codex"), sharedBefore)
    }

    func testSnapshotDigestIsStableAcrossFingerprintOrderAndRoundTrip() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let expected = try fixture.rotatedTarget.snapshotDigest()
        let variants = [Array(["first", "second", "third"]), ["third", "first", "second"]]
        for values in variants {
            var entry = fixture.rotatedTarget
            entry.codexStaleSharedCredentialFingerprints = Set(values)
            XCTAssertEqual(try entry.snapshotDigest(), expected)
            let restored = try JSONDecoder().decode(
                AccountCredentialVault.Entry.self, from: JSONEncoder().encode(entry)
            )
            XCTAssertEqual(try restored.snapshotDigest(), expected)
        }
        var changed = fixture.rotatedTarget
        changed.credential += " "
        XCTAssertNotEqual(try changed.snapshotDigest(), expected)
    }

    private func assertSwitched(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.target.id, file: file, line: line)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.rotatedPrevious, file: file, line: line)
        var synchronized = fixture.rotatedTarget
        synchronized.codexStaleSharedCredentialFingerprints = nil
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.target), synchronized, file: file, line: line)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), synchronized, file: file, line: line)
        XCTAssertNil(try fixture.switcher.switchJournal.load(), file: file, line: line)
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let keychain = ServiceKeychain()
        let workspace: AccountSignInWorkspace
        let switcher: AccountCredentialSwitcher
        let store: AccountProfilesStore
        let previous: AccountProfile
        let target: AccountProfile
        let rotatedPrevious: AccountCredentialVault.Entry
        let rotatedTarget: AccountCredentialVault.Entry

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountSwitchCodexPreservation-\(UUID().uuidString)")
                .resolvingSymlinksInPath().standardizedFileURL
            suite = "AccountSwitchCodexPreservation-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
            switcher = AccountCredentialSwitcher(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
            store = AccountProfilesStore(defaults: defaults)
            previous = try store.add(family: "codex", label: "A", identityKey: "account-a", id: "profile-a")
            target = try store.add(family: "codex", label: "B", identityKey: "account-b", id: "profile-b")
            let stalePrevious = Self.entry(account: "a", token: "stale-a")
            var departing = Self.entry(account: "a", token: "rotated-a")
            departing.codexStaleSharedCredentialFingerprints = [CodexAuthStore.credentialFingerprint(stalePrevious.credential)]
            rotatedPrevious = departing
            var selected = Self.entry(account: "b", token: "rotated-b")
            selected.codexStaleSharedCredentialFingerprints = ["first", "second", "third"]
            rotatedTarget = selected
            try switcher.saveSnapshot(rotatedPrevious, for: previous)
            try switcher.saveSnapshot(rotatedTarget, for: target)
            try switcher.applySharedAuthentication(stalePrevious, family: "codex")
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        private static func entry(account: String, token: String) -> AccountCredentialVault.Entry {
            .init(
                credential: #"{"tokens":{"access_token":"\#(token)","refresh_token":"refresh-\#(token)","account_id":"account-\#(account)"}}"#,
                claudeOAuthAccount: nil
            )
        }
    }
}
