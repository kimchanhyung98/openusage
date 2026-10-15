import XCTest
@testable import OpenUsage

@MainActor
final class AccountIdentityReplacementRecoveryTests: XCTestCase {
    func testSameIdentityRecoveryBeforeSnapshotWritePreservesFreshWorkspaceCredential() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.store.beginIdentityReplacement(
            profileID: fixture.profile.id,
            with: "acct-a",
            replacesSharedAuthentication: true,
            replacementSnapshotDigest: fixture.fresh.snapshotDigest()
        )
        let reloaded = AccountProfilesStore(defaults: fixture.defaults)

        XCTAssertFalse(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))

        try assertFreshWorkspace(fixture)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), fixture.previous)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.previous)
        XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "acct-a")
        XCTAssertEqual(reloaded.preferredProfileID(family: "codex"), fixture.profile.id)
        XCTAssertNil(try reloaded.pendingIdentityReplacement())
    }

    func testRecoveryAfterIntendedSnapshotWriteCompletesOnceForSameOrDifferentIdentity() throws {
        for identity in ["acct-a", "acct-b"] {
            let fixture = try makeFixture(freshIdentity: identity)
            defer { fixture.cleanup() }
            _ = try fixture.store.beginIdentityReplacement(
                profileID: fixture.profile.id,
                with: identity,
                replacesSharedAuthentication: true,
                replacementSnapshotDigest: fixture.fresh.snapshotDigest()
            )
            try fixture.switcher.saveSnapshot(fixture.fresh, for: fixture.profile)
            let reloaded = AccountProfilesStore(defaults: fixture.defaults)

            XCTAssertTrue(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))

            try assertFreshWorkspace(fixture)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), fixture.fresh)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.fresh)
            XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, identity)
            XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.label, fixture.profile.label)
            XCTAssertEqual(reloaded.preferredProfileID(family: "codex"), fixture.profile.id)
            XCTAssertNil(try reloaded.pendingIdentityReplacement())
            let revision = reloaded.authenticationRevision
            XCTAssertFalse(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))
            XCTAssertEqual(reloaded.authenticationRevision, revision)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.fresh)
        }
    }

    func testLegacySameIdentityJournalCannotProveAnOldSnapshotIsFresh() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let legacy = #"{"profileID":"profile-a","previousIdentityKey":"acct-a","replacementIdentityKey":"acct-a","replacesSharedAuthentication":true}"#
        fixture.defaults.set(Data(legacy.utf8), forKey: AccountProfilesStore.identityReplacementKey)
        let reloaded = AccountProfilesStore(defaults: fixture.defaults)
        XCTAssertNotNil(try reloaded.pendingIdentityReplacement())

        XCTAssertFalse(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))

        try assertFreshWorkspace(fixture)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), fixture.previous)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.previous)
        XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "acct-a")
        XCTAssertNil(try reloaded.pendingIdentityReplacement())
    }

    func testDeniedOrCorruptSnapshotPreservesFreshWorkspaceSharedHomeAndPendingJournal() throws {
        for denied in [true, false] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            let transaction = try fixture.store.beginIdentityReplacement(
                profileID: fixture.profile.id,
                with: "acct-a",
                replacesSharedAuthentication: true,
                replacementSnapshotDigest: fixture.fresh.snapshotDigest()
            )
            let service = AccountCredentialVault.service(family: "codex", profileID: fixture.profile.id)
            if denied {
                fixture.keychain.deniedSnapshotService = service
            } else {
                fixture.keychain.storage.currentUserValues[service] = "invalid-snapshot-json"
            }
            let rawSnapshot = fixture.keychain.storage.currentUserValues[service]
            let reloaded = AccountProfilesStore(defaults: fixture.defaults)

            XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded)) { error in
                if denied {
                    XCTAssertEqual(error as? RecoverySnapshotKeychain.ReadFailure, .denied)
                } else {
                    XCTAssertTrue(error is AccountCredentialVaultError)
                }
            }

            try assertFreshWorkspace(fixture)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.previous)
            XCTAssertEqual(fixture.keychain.storage.currentUserValues[service], rawSnapshot)
            XCTAssertEqual(try reloaded.pendingIdentityReplacement(), transaction)
            XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "acct-a")
            XCTAssertEqual(reloaded.preferredProfileID(family: "codex"), fixture.profile.id)
        }
    }

    func testRecoveryBeforeFirstSnapshotWritePreservesAbsentOrIncompleteSharedAuthentication() throws {
        for sharedData in [nil, Data("incomplete-auth".utf8), Data(#"{"tokens":{"access_token":"old-token","account_id":"acct-a"}}"#.utf8)] {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            try AccountCredentialVault(keychain: fixture.keychain).delete(profile: fixture.profile)
            let sharedURL = fixture.root.appendingPathComponent(".codex/auth.json")
            if let sharedData {
                try sharedData.write(to: sharedURL)
            } else {
                try FileManager.default.removeItem(at: sharedURL)
            }
            let artifacts = fixture.switcher.credentialArtifacts
            let original = try artifacts.capture(family: "codex")
            _ = try fixture.store.beginIdentityReplacement(
                profileID: fixture.profile.id, with: "acct-a", replacesSharedAuthentication: true,
                replacementSnapshotDigest: fixture.fresh.snapshotDigest(),
                originalSharedAuthenticationDigest: artifacts.authenticationDigest(of: original)
            )
            let restarted = AccountProfilesStore(defaults: fixture.defaults)

            XCTAssertFalse(try fixture.importer.recoverInterruptedIdentityReplacement(in: restarted))

            XCTAssertNil(try restarted.pendingIdentityReplacement())
            XCTAssertNil(try fixture.switcher.loadSnapshot(for: fixture.profile))
            XCTAssertEqual(try artifacts.capture(family: "codex"), original)
            try assertFreshWorkspace(fixture)
        }
    }

    func testMissingSnapshotAndChangedSharedAuthenticationRetainTheRecoveryJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        try AccountCredentialVault(keychain: fixture.keychain).delete(profile: fixture.profile)
        let artifacts = fixture.switcher.credentialArtifacts
        let original = try artifacts.capture(family: "codex")
        let transaction = try fixture.store.beginIdentityReplacement(
            profileID: fixture.profile.id, with: "acct-a", replacesSharedAuthentication: true,
            replacementSnapshotDigest: fixture.fresh.snapshotDigest(),
            originalSharedAuthenticationDigest: artifacts.authenticationDigest(of: original)
        )
        try fixture.switcher.applySharedAuthentication(fixture.fresh, family: "codex")
        let current = try artifacts.capture(family: "codex")
        let restarted = AccountProfilesStore(defaults: fixture.defaults)

        XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: restarted))

        XCTAssertEqual(try restarted.pendingIdentityReplacement(), transaction)
        XCTAssertEqual(try artifacts.capture(family: "codex"), current)
        try assertFreshWorkspace(fixture)
    }

    func testPartialCredentialWriteCanFinishTheIntendedReplacement() async throws {
        for (afterStartup, afterRootWrite) in [(false, false), (true, false), (false, true), (true, true)] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountIdentityRecoveryPartial-\(UUID().uuidString)")
                .resolvingSymlinksInPath().standardizedFileURL
            let suite = "AccountIdentityRecoveryPartial-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let keychain = ServiceKeychain()
            let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
            let switcher = AccountCredentialSwitcher(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
            let importer = AccountCredentialImporter(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
            let store = AccountProfilesStore(defaults: defaults)
            let profile = try store.add(
                family: "claude", label: "Work", identityKey: "acct-a|org-a", id: "profile-a"
            )
            let previous = claudeEntry(account: "a")
            let replacement = claudeEntry(account: "b")
            try switcher.applySharedAuthentication(previous, family: "claude")
            _ = try store.beginIdentityReplacement(
                profileID: profile.id, with: "acct-b|org-b", replacesSharedAuthentication: true,
                replacementSnapshotDigest: replacement.snapshotDigest()
            )
            try switcher.saveSnapshot(replacement, for: profile)
            let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: switcher.sharedHomePath(family: "claude"), environment: FakeEnvironment()
            )
            keychain.currentUserValues[scopedService] = replacement.credential
            keychain.currentUserModificationDates[scopedService] = Date().addingTimeInterval(60)
            if afterRootWrite {
                let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())
                keychain.currentUserValues[baseService] = replacement.credential
                keychain.currentUserModificationDates[baseService] = Date().addingTimeInterval(60)
                try writeState(replacement, to: root.appendingPathComponent(".claude.json"),
                               time: Date().addingTimeInterval(120).timeIntervalSince1970)
            }

            if afterStartup {
                let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)
                XCTAssertEqual(result, .recoveredAuthentication)
            } else {
                XCTAssertTrue(try importer.recoverInterruptedIdentityReplacement(in: store))
            }

            XCTAssertEqual(try switcher.readSharedAuthentication(family: "claude"), replacement)
            XCTAssertEqual(try switcher.loadSnapshot(for: profile), replacement)
            XCTAssertEqual(store.profile(id: profile.id)?.identityKey, "acct-b|org-b")
            XCTAssertNil(try store.pendingIdentityReplacement())
        }
    }

    private func claudeEntry(account: String) -> AccountCredentialVault.Entry {
        AccountCredentialVault.Entry(
            credential: #"{"claudeAiOauth":{"accessToken":"token-\#(account)","refreshToken":"refresh-\#(account)"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
        )
    }

    private func writeState(_ entry: AccountCredentialVault.Entry, to url: URL, time: TimeInterval) throws {
        let account = try XCTUnwrap(entry.claudeOAuthAccount)
        try Data(#"{"keep":true,"oauthAccount":\#(account)}"#.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path
        )
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let keychain: RecoverySnapshotKeychain
        let store: AccountProfilesStore
        let profile: AccountProfile
        let switcher: AccountCredentialSwitcher
        let importer: AccountCredentialImporter
        let previous: AccountCredentialVault.Entry
        let fresh: AccountCredentialVault.Entry

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeFixture(freshIdentity: String = "acct-a") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountIdentityReplacementRecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AccountIdentityReplacementRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keychain = RecoverySnapshotKeychain()
        let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: FakeEnvironment(),
            homeDirectory: root,
            workspace: workspace
        )
        let importer = AccountCredentialImporter(
            keychain: keychain,
            environment: FakeEnvironment(),
            homeDirectory: root,
            workspace: workspace
        )
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try store.add(
            family: "codex", label: "alpha", identityKey: "acct-a", id: "profile-a"
        )
        let previous = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"old-token","account_id":"acct-a"}}"#,
            claudeOAuthAccount: nil
        )
        let fresh = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"fresh-token","account_id":"\#(freshIdentity)"}}"#,
            claudeOAuthAccount: nil
        )
        try switcher.saveSnapshot(previous, for: profile)
        try switcher.applySharedAuthentication(previous, family: "codex")
        try switcher.writeWorkspaceAuthentication(fresh, for: profile)
        return Fixture(
            root: root, suite: suite, defaults: defaults, keychain: keychain,
            store: store, profile: profile, switcher: switcher, importer: importer,
            previous: previous, fresh: fresh
        )
    }

    private func assertFreshWorkspace(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(
            try fixture.importer.readWorkspaceCredential(family: "codex", profileID: fixture.profile.id)?.entry,
            fixture.fresh, file: file, line: line
        )
    }
}

private final class RecoverySnapshotKeychain: KeychainAccessing, @unchecked Sendable {
    enum ReadFailure: Error, Equatable {
        case denied
    }

    let storage = ServiceKeychain()
    var deniedSnapshotService: String?

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        guard service != deniedSnapshotService else { throw ReadFailure.denied }
        return forCurrentUser
            ? try storage.readGenericPasswordForCurrentUser(service: service)
            : try storage.readGenericPassword(service: service)
    }

    func readGenericPassword(service: String) throws -> String? {
        try storage.readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try storage.readGenericPasswordForCurrentUser(service: service)
    }

    func genericPasswordExists(service: String) -> Bool? {
        storage.currentUserValues[service] != nil || storage.values[service] != nil
    }

    func writeGenericPassword(service: String, value: String) throws {
        try storage.writeGenericPassword(service: service, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try storage.writeGenericPasswordForCurrentUser(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try storage.deleteGenericPassword(service: service)
    }

    func deleteGenericPasswordForCurrentUser(service: String) throws {
        storage.currentUserValues.removeValue(forKey: service)
        storage.currentUserModificationDates.removeValue(forKey: service)
    }
}
