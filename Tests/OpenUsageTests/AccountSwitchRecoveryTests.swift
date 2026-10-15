import XCTest
@testable import OpenUsage

@MainActor
final class AccountSwitchRecoveryTests: XCTestCase {
    func testRestartBeforeApplyCancelsSwitchWithoutChangingOriginalAuthentication() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transition = try fixture.beginSwitch()
        let restarted = fixture.restartedStore()
        let switcher = fixture.restartedSwitcher()

        XCTAssertFalse(try switcher.recoverInterruptedSwitch(in: restarted))

        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.previous.id)
        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), transition.original)
        XCTAssertEqual(try switcher.loadSnapshot(for: fixture.target), fixture.targetEntry)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertFalse(try switcher.recoverInterruptedSwitch(in: restarted))
    }

    func testRestartAfterApplyRecoversSelectionBeforeClaudeExternalReconciliation() async throws {
        for cancelAfterCommit in [false, true] {
            let fixture = try makeFixture(family: "claude")
            defer { fixture.cleanup() }
            _ = try fixture.beginSwitch()
            try fixture.switcher.applySharedAuthentication(fixture.targetEntry, family: "claude")
            let restarted = fixture.restartedStore()
            let importer = AccountCredentialImporter(
                keychain: fixture.keychain,
                environment: FakeEnvironment(),
                homeDirectory: fixture.root,
                workspace: fixture.workspace
            )
            fixture.keychain.assertBackgroundReads = true
            defer { fixture.keychain.assertBackgroundReads = false }
            let recoveryTask = Task {
                try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: restarted)
            }
            if cancelAfterCommit {
                fixture.keychain.onJournalDeletion = { recoveryTask.cancel() }
            }

            let result = try await recoveryTask.value
            fixture.keychain.assertBackgroundReads = false
            fixture.keychain.onJournalDeletion = nil

            XCTAssertEqual(result, .recoveredAuthentication)
            XCTAssertEqual(recoveryTask.isCancelled, cancelAfterCommit)
            let readServices = fixture.keychain.backgroundReadServices
            XCTAssertTrue(readServices.contains(AccountSwitchJournal.service))
            XCTAssertTrue(readServices.contains(
                AccountCredentialVault.service(family: "claude", profileID: fixture.target.id)
            ))
            XCTAssertTrue(readServices.contains(ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: fixture.switcher.sharedHomePath(family: "claude"),
                environment: FakeEnvironment()
            )))
            XCTAssertTrue(readServices.contains(
                ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())
            ))
            XCTAssertEqual(restarted.preferredProfileID(family: "claude"), fixture.target.id)
            XCTAssertEqual(restarted.profile(id: fixture.previous.id), fixture.previous)
            XCTAssertEqual(restarted.profile(id: fixture.target.id), fixture.target)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.previousEntry)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.target), fixture.targetEntry)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.targetEntry)
            XCTAssertNil(try fixture.journal.load())
            XCTAssertEqual(try importer.reconcileSelectedClaudeSharedAuthentication(in: restarted), .unchanged)
        }
    }

    func testRestartAfterSelectionCommitOnlyClearsJournal() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        _ = try fixture.beginSwitch()
        try fixture.switcher.applySharedAuthentication(fixture.targetEntry, family: "codex")
        fixture.store.setPreferred(family: "codex", profileID: fixture.target.id)
        let committed = try fixture.artifacts.capture(family: "codex")
        let restarted = fixture.restartedStore()

        XCTAssertFalse(try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restarted))

        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), committed)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.previousEntry)
        XCTAssertNil(try fixture.journal.load())
    }

    func testSelectionPersistenceFailureKeepsAppliedAuthenticationUntilRestartCompletesSwitch() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let defaults = try XCTUnwrap(FailingSelectionDefaults(suiteName: fixture.suite))
        let store = AccountProfilesStore(defaults: defaults)
        let originalRegistry = defaults.data(forKey: AccountProfilesStore.storageKey)
        defaults.rejectNextWriteForKey = AccountProfilesStore.storageKey

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: fixture.target, in: store))

        XCTAssertEqual(defaults.rejectedWriteCount, 1)
        XCTAssertEqual(defaults.data(forKey: AccountProfilesStore.storageKey), originalRegistry)
        XCTAssertEqual(store.preferredProfileID(family: "codex"), fixture.previous.id)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.targetEntry)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.previousEntry)
        let pending = try XCTUnwrap(fixture.journal.load())
        XCTAssertEqual(pending.previousProfileID, fixture.previous.id)
        XCTAssertEqual(pending.targetProfileID, fixture.target.id)
        XCTAssertTrue(try fixture.artifacts.matches(pending.applied))
        let restarted = fixture.restartedStore()
        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.previous.id)

        XCTAssertTrue(try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restarted))

        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(fixture.restartedStore().preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(restarted.profile(id: fixture.previous.id), fixture.previous)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.targetEntry)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.target), fixture.targetEntry)
        XCTAssertNil(try fixture.journal.load())
    }

    func testRestartWithDeletedTargetRestoresOriginalWithoutRecreatingTarget() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transition = try fixture.beginSwitch()
        try fixture.switcher.applySharedAuthentication(fixture.targetEntry, family: "codex")
        try AccountCredentialVault(keychain: fixture.keychain).delete(profile: fixture.target)
        try fixture.store.archive(profileID: fixture.target.id)
        let restarted = fixture.restartedStore()

        _ = try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restarted)

        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.previous.id)
        XCTAssertNil(restarted.profile(id: fixture.target.id))
        XCTAssertNil(try fixture.switcher.loadSnapshot(for: fixture.target))
        try assertRestoredCodexArtifacts(
            fixture.artifacts.capture(family: "codex"), expected: transition.original
        )
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.previousEntry)
        XCTAssertNil(try fixture.journal.load())
    }

    func testRestartWithReauthenticatedTargetPreservesItsReplacementSnapshotAndWorkspace() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transition = try fixture.beginSwitch()
        try fixture.switcher.applySharedAuthentication(fixture.targetEntry, family: "codex")
        let replacement = entry(family: "codex", account: "c")
        let rebound = try fixture.store.replaceIdentity(profileID: fixture.target.id, with: "acct-c")
        try fixture.switcher.saveSnapshot(replacement, for: rebound)
        try fixture.switcher.writeWorkspaceAuthentication(replacement, for: rebound)
        let restarted = fixture.restartedStore()

        _ = try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restarted)

        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.previous.id)
        XCTAssertEqual(restarted.profile(id: fixture.target.id), rebound)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: rebound), replacement)
        let workspaceHome = try fixture.workspace.directory(family: "codex", profileID: rebound.id)
        XCTAssertEqual(
            try fixture.switcher.readAuthentication(family: "codex", home: workspaceHome.path),
            replacement
        )
        try assertRestoredCodexArtifacts(
            fixture.artifacts.capture(family: "codex"), expected: transition.original
        )
        XCTAssertNil(try fixture.journal.load())
    }

    func testCleanupFailureNeverRollsBackCommittedSwitchAcrossRestarts() throws {
        let keychain = SwitchRecoveryKeychain()
        let fixture = try makeFixture(keychain: keychain)
        defer { fixture.cleanup() }
        keychain.failJournalDeletion = true

        XCTAssertNoThrow(try fixture.switcher.switchAuthentication(to: fixture.target, in: fixture.store))

        XCTAssertGreaterThan(keychain.journalDeletionAttempts, 0)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.targetEntry)
        let pending = try XCTUnwrap(fixture.journal.load())
        let committed = try fixture.artifacts.capture(family: "codex")
        let previousWorkspaceAuth = try fixture.workspace.directory(family: "codex", profileID: fixture.previous.id)
            .appendingPathComponent("auth.json")
        let workspaceBefore = try Data(contentsOf: previousWorkspaceAuth)
        let importer = AccountCredentialImporter(
            keychain: keychain,
            environment: FakeEnvironment(),
            homeDirectory: fixture.root,
            workspace: fixture.workspace
        )

        XCTAssertThrowsError(try importer.removeAccount(fixture.previous, from: fixture.store)) {
            XCTAssertEqual($0 as? AccountSwitchJournal.Error, .pendingTransition)
        }

        XCTAssertEqual(fixture.store.profile(id: fixture.previous.id), fixture.previous)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.previousEntry)
        XCTAssertEqual(try Data(contentsOf: previousWorkspaceAuth), workspaceBefore)
        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), committed)
        XCTAssertEqual(try fixture.journal.load(), pending)
        let restarted = fixture.restartedStore()

        XCTAssertNoThrow(try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restarted))

        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), committed)
        XCTAssertEqual(try fixture.journal.load(), pending)
        keychain.failJournalDeletion = false
        let restartedAgain = fixture.restartedStore()

        XCTAssertFalse(try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restartedAgain))

        XCTAssertEqual(restartedAgain.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), committed)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.previous), fixture.previousEntry)
        XCTAssertNil(try fixture.journal.load())
    }

    func testCommittedSwitchCleanupPreservesRotatedOrReauthenticatedCredentialsWithoutReadingThem() throws {
        for (account, token) in [("b", "rotated-token-b"), ("c", "new-login-token-c")] {
            let keychain = SwitchRecoveryKeychain()
            let fixture = try makeFixture(family: "claude", keychain: keychain)
            defer { fixture.cleanup() }
            keychain.failJournalDeletion = true
            try fixture.switcher.switchAuthentication(to: fixture.target, in: fixture.store)
            XCTAssertNotNil(try fixture.journal.load())
            let replacement = entry(family: "claude", account: account, token: token)
            let identityKey = try XCTUnwrap(
                fixture.switcher.identity(of: replacement, family: "claude")?.identityKey
            )
            let current = try fixture.store.replaceIdentity(profileID: fixture.target.id, with: identityKey)
            try fixture.switcher.saveSnapshot(replacement, for: current)
            try fixture.switcher.applySharedAuthentication(replacement, family: "claude")
            let sharedBefore = try fixture.artifacts.capture(family: "claude")
            let registryBefore = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)
            let restarted = fixture.restartedStore()
            keychain.failJournalDeletion = false
            keychain.credentialReadCount = 0
            keychain.rejectCredentialReads = true
            let writesBefore = keychain.credentialWriteCount

            XCTAssertFalse(try fixture.restartedSwitcher().recoverInterruptedSwitch(in: restarted))

            XCTAssertEqual(keychain.credentialReadCount, 0)
            XCTAssertEqual(keychain.credentialWriteCount, writesBefore)
            keychain.rejectCredentialReads = false
            XCTAssertEqual(restarted.preferredProfileID(family: "claude"), fixture.target.id)
            XCTAssertEqual(restarted.profile(id: fixture.target.id), current)
            XCTAssertEqual(fixture.defaults.data(forKey: AccountProfilesStore.storageKey), registryBefore)
            XCTAssertEqual(try fixture.artifacts.capture(family: "claude"), sharedBefore)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: current), replacement)
            XCTAssertNil(try fixture.journal.load())
        }
    }

    func testFailedCodexSwitchRecoveryReportsCodexWithoutChangingTheExternalLogin() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let transaction = try fixture.beginSwitch()
        let external = entry(family: "codex", account: "c")
        try fixture.switcher.applySharedAuthentication(external, family: "codex")
        let importer = AccountCredentialImporter(
            keychain: fixture.keychain, environment: FakeEnvironment(),
            homeDirectory: fixture.root, workspace: fixture.workspace
        )
        do {
            _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
            XCTFail("Expected the interrupted Codex switch to preserve the external login")
        } catch {
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .switchRecoveryFailed)
        }

        let failure = await importer.reconciliationFailure(
            for: AccountCredentialSwitcher.Error.switchRecoveryFailed, in: fixture.store
        )

        XCTAssertEqual(failure.families, ["codex"])
        XCTAssertEqual(try fixture.journal.load(), transaction)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.previous.id)
    }

    private func assertRestoredCodexArtifacts(
        _ actual: AccountCredentialArtifacts.Snapshot,
        expected: AccountCredentialArtifacts.Snapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case .codex(let actualFile) = actual, case .codex(let expectedFile) = expected else {
            return XCTFail("Expected Codex credential artifacts", file: file, line: line)
        }
        XCTAssertEqual(actualFile.data, expectedFile.data, file: file, line: line)
        XCTAssertEqual(actualFile.permissions, expectedFile.permissions, file: file, line: line)
        let actualDate = try XCTUnwrap(actualFile.modificationDate, file: file, line: line)
        let expectedDate = try XCTUnwrap(expectedFile.modificationDate, file: file, line: line)
        let actualTime = actualDate.timeIntervalSinceReferenceDate
        let expectedTime = expectedDate.timeIntervalSinceReferenceDate
        XCTAssertEqual(
            actualTime, expectedTime, accuracy: 0.000001,
            "Restored mtime delta: \(actualTime - expectedTime) seconds", file: file, line: line
        )
    }

    private func makeFixture(
        family: String = "codex",
        keychain: SwitchRecoveryKeychain = SwitchRecoveryKeychain()
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountSwitchRecoveryTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AccountSwitchRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: FakeEnvironment(),
            homeDirectory: root,
            workspace: workspace
        )
        let store = AccountProfilesStore(defaults: defaults)
        let previousEntry = entry(family: family, account: "a")
        let targetEntry = entry(family: family, account: "b")
        let previous = try store.add(
            family: family,
            label: "Personal",
            identityKey: try XCTUnwrap(switcher.identity(of: previousEntry, family: family)?.identityKey),
            id: "profile-a"
        )
        let target = try store.add(
            family: family,
            label: "Work",
            identityKey: try XCTUnwrap(switcher.identity(of: targetEntry, family: family)?.identityKey),
            id: "profile-b"
        )
        try switcher.saveSnapshot(previousEntry, for: previous)
        try switcher.saveSnapshot(targetEntry, for: target)
        try switcher.applySharedAuthentication(previousEntry, family: family)
        return Fixture(
            root: root,
            suite: suite,
            defaults: defaults,
            keychain: keychain,
            workspace: workspace,
            store: store,
            switcher: switcher,
            previous: previous,
            target: target,
            previousEntry: previousEntry,
            targetEntry: targetEntry
        )
    }

    private func entry(family: String, account: String, token: String? = nil) -> AccountCredentialVault.Entry {
        let token = token ?? "token-\(account)"
        if family == "claude" {
            return .init(
                credential: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(account)","scopes":["user:profile","user:inference"]}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
            )
        }
        return .init(
            credential: #"{"tokens":{"access_token":"\#(token)","account_id":"acct-\#(account)"}}"#,
            claudeOAuthAccount: nil
        )
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let keychain: SwitchRecoveryKeychain
        let workspace: AccountSignInWorkspace
        let store: AccountProfilesStore
        let switcher: AccountCredentialSwitcher
        let previous: AccountProfile
        let target: AccountProfile
        let previousEntry: AccountCredentialVault.Entry
        let targetEntry: AccountCredentialVault.Entry

        var artifacts: AccountCredentialArtifacts {
            AccountCredentialArtifacts(
                keychain: keychain,
                environment: FakeEnvironment(),
                homeDirectory: root
            )
        }

        var journal: AccountSwitchJournal { AccountSwitchJournal(keychain: keychain) }

        func beginSwitch() throws -> AccountSwitchTransition {
            let original = try artifacts.capture(family: target.family)
            let transition = try AccountSwitchTransition(
                family: target.family,
                previousProfileID: previous.id,
                targetProfileID: target.id,
                targetIdentityKey: target.identityKey,
                targetSnapshotDigest: targetEntry.snapshotDigest(),
                original: original,
                applied: artifacts.applying(targetEntry, to: original)
            )
            try journal.save(transition)
            return transition
        }

        func restartedStore() -> AccountProfilesStore {
            AccountProfilesStore(defaults: defaults)
        }

        func restartedSwitcher() -> AccountCredentialSwitcher {
            AccountCredentialSwitcher(
                keychain: keychain,
                environment: FakeEnvironment(),
                homeDirectory: root,
                workspace: workspace
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class FailingSelectionDefaults: UserDefaults {
    var rejectNextWriteForKey: String?
    private(set) var rejectedWriteCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if rejectNextWriteForKey == defaultName {
            rejectNextWriteForKey = nil
            rejectedWriteCount += 1
            return
        }
        super.set(value, forKey: defaultName)
    }
}

private final class SwitchRecoveryKeychain: KeychainAccessing, @unchecked Sendable {
    private let base = ServiceKeychain()
    var failJournalDeletion = false
    var rejectCredentialReads = false
    var assertBackgroundReads = false
    var onJournalDeletion: (@Sendable () -> Void)?
    var credentialReadCount = 0
    private(set) var backgroundReadServices: Set<String> = []
    private(set) var credentialWriteCount = 0
    private(set) var journalDeletionAttempts = 0

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        if forCurrentUser {
            return try readGenericPasswordForCurrentUser(service: service)
        }
        return try readGenericPassword(service: service)
    }

    func readGenericPassword(service: String) throws -> String? {
        try recordCredentialRead(service: service)
        return try base.readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try recordCredentialRead(service: service)
        return try base.readGenericPasswordForCurrentUser(service: service)
    }

    func genericPasswordExists(service: String) -> Bool? {
        base.values[service] != nil || base.currentUserValues[service] != nil
    }

    func writeGenericPassword(service: String, value: String) throws {
        if service != AccountSwitchJournal.service { credentialWriteCount += 1 }
        try base.writeGenericPassword(service: service, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        if service != AccountSwitchJournal.service { credentialWriteCount += 1 }
        try base.writeGenericPasswordForCurrentUser(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try checkDeletion(service: service)
        try base.deleteGenericPassword(service: service)
    }

    func deleteGenericPasswordForCurrentUser(service: String) throws {
        try checkDeletion(service: service)
        base.currentUserValues.removeValue(forKey: service)
        base.currentUserModificationDates.removeValue(forKey: service)
        if service == AccountSwitchJournal.service { onJournalDeletion?() }
    }

    func genericPasswordModificationDate(service: String) throws -> Date? {
        try base.genericPasswordModificationDate(service: service)
    }

    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date? {
        try base.genericPasswordModificationDateForCurrentUser(service: service)
    }

    private func recordCredentialRead(service: String) throws {
        if assertBackgroundReads {
            XCTAssertFalse(Thread.isMainThread, "Account switch recovery read a Keychain secret on the main thread")
            backgroundReadServices.insert(service)
        }
        guard service != AccountSwitchJournal.service else { return }
        credentialReadCount += 1
        if rejectCredentialReads {
            throw NSError(domain: "SwitchRecoveryKeychain", code: 2)
        }
    }

    private func checkDeletion(service: String) throws {
        guard service == AccountSwitchJournal.service else { return }
        journalDeletionAttempts += 1
        if failJournalDeletion {
            throw NSError(domain: "SwitchRecoveryKeychain", code: 1)
        }
    }
}
