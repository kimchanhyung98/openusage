import XCTest
@testable import OpenUsage

@MainActor
final class AccountSwitchRecoveryTests: XCTestCase {
    func testProductionTransactionPersistsSelectionAndPreservesRotatedDeparture() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = AccountSwitchRecoveryFixture.entry("a", token: "rotated-a")
        try fixture.switcher.applySharedAuthentication(rotated, family: "claude")
        var sawJournalBeforeSharedWrite = false
        let journal = fixture.journal
        let scopedService = fixture.scopedService
        fixture.keychain.beforeWrite = { service, _ in
            if service == scopedService {
                sawJournalBeforeSharedWrite = try journal.load() != nil
            }
        }

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertTrue(sawJournalBeforeSharedWrite)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), rotated)
        try fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.journal.load())
    }

    func testSharedCommitBeforeSelectionPersistenceRecoversWithoutOverwritingA() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { false })
        let originalRegistry = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)
        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store))
        XCTAssertNotNil(try fixture.journal.load())
        fixture.defaults.set(originalRegistry, forKey: AccountProfilesStore.storageKey)
        let reloaded = try fixture.freshStore()
        let writesBefore = fixture.keychain.writeCount

        let result = try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded)

        XCTAssertEqual(result, .updated(profileID: fixture.b.id))
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded), .unchanged)
    }

    func testScopedOnlyRotationPreservesDepartureAndRoundTrips() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = try fixture.rotateScopedCredentials()
        XCTAssertNotEqual(rotated.credential, fixture.entryA.credential)
        XCTAssertEqual(fixture.keychain.currentUserValues[fixture.baseService], fixture.entryA.credential)

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), rotated)
        let home = try fixture.workspace.directory(family: "claude", profileID: fixture.a.id).path
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), rotated)
        try fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
    }

    func testScopedAccessAndRefreshRotationPreservesDepartureWithoutNewAccountState() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = try fixture.rotateScopedCredentials(replacingRefreshToken: true)
        let credentialDate = Date(timeIntervalSince1970: 2_000_000_000)
        fixture.keychain.currentUserModificationDates[fixture.scopedService] = credentialDate
        for path in [".claude.json", ".claude/.claude.json"] {
            try FileManager.default.setAttributes(
                [.modificationDate: credentialDate.addingTimeInterval(-1)],
                ofItemAtPath: fixture.root.appendingPathComponent(path).path
            )
        }

        XCTAssertNotEqual(rotated.credential, fixture.entryA.credential)
        XCTAssertEqual(fixture.keychain.currentUserValues[fixture.baseService], fixture.entryA.credential)
        XCTAssertEqual(
            ClaudeAuthStore.parseCredentials(rotated.credential)?.claudeAiOauth?.refreshToken,
            "rotated-refresh-a"
        )

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), rotated)
        let home = try fixture.workspace.directory(family: "claude", profileID: fixture.a.id).path
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), rotated)
        try fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
    }

    func testPendingRetryDoesNotPreserveDivergentSameChainCredential() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        _ = try fixture.rotateScopedCredentials()

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testFileOnlyDepartureWithMatchingSnapshotRemainsSwitchable() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        fixture.keychain.currentUserValues.removeValue(forKey: fixture.scopedService)
        fixture.keychain.currentUserValues.removeValue(forKey: fixture.baseService)

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), fixture.entryA)
        try fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
    }

    func testStartupRecoveryCompletesTargetSelectionBeforeExternalReconciliation() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let reloaded = try fixture.freshStore()
        let writesBefore = fixture.keychain.writeCount

        let result = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)

        XCTAssertEqual(result, .updated(profileID: fixture.b.id))
        XCTAssertEqual(reloaded.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testPersistedSelectionWithUnremovedJournalRecoversIdempotently() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let files = SwitchJournalFiles()
        files.failRemove = true
        let service = AccountSelectionSwitcher(
            switcher: fixture.switcher, journal: AccountSwitchJournal(path: fixture.journal.path, files: files)
        )
        XCTAssertThrowsError(try service.switchAuthentication(to: fixture.b, in: fixture.store))
        let reloaded = try fixture.freshStore()
        XCTAssertEqual(reloaded.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNotNil(try fixture.journal.load())

        XCTAssertEqual(
            try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded),
            .updated(profileID: fixture.b.id)
        )
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testJournalWriteFailurePreventsCredentialAndSelectionWrites() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let files = SwitchJournalFiles()
        files.failWrite = true
        let service = AccountSelectionSwitcher(
            switcher: fixture.switcher, journal: AccountSwitchJournal(path: fixture.journal.path, files: files)
        )
        let before = try fixture.switcher.readClaudeSwitchState()
        let writesBefore = fixture.keychain.writeCount

        XCTAssertThrowsError(try service.switchAuthentication(to: fixture.b, in: fixture.store))

        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testFailureBeforeSharedMutationRecoversTheOriginalSelection() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let snapshotService = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        fixture.keychain.beforeWrite = { service, _ in
            if service == snapshotService { throw SwitchRecoveryKeychain.Failure.injected }
        }
        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store))
        XCTAssertNotNil(try fixture.journal.load())
        fixture.keychain.beforeWrite = nil

        XCTAssertEqual(
            try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: fixture.freshStore()),
            .updated(profileID: fixture.a.id)
        )
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testPartialWriteAndFailedRollbackBlockBothReconciliationPaths() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let base = fixture.baseService
        let scoped = fixture.scopedService
        let credentialA = fixture.entryA.credential
        fixture.keychain.beforeWrite = { service, value in
            if service == base || (service == scoped && value == credentialA) {
                throw SwitchRecoveryKeychain.Failure.injected
            }
        }
        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store))
        fixture.keychain.beforeWrite = nil
        let record = try XCTUnwrap(fixture.journal.load())
        let before = try fixture.switcher.readClaudeSwitchState()
        let writesBefore = fixture.keychain.writeCount
        XCTAssertNotEqual(before.credentials[0], before.credentials[1])
        let reloaded = try fixture.freshStore()

        XCTAssertThrowsError(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded))
        do {
            _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)
            XCTFail("Mixed authentication must keep the pending switch blocked")
        } catch {}

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertEqual(reloaded.preferredProfileID(family: "claude"), fixture.a.id)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testNewExternalAndSameIdentityNewGenerationStayUntouched() throws {
        for entry in [AccountSwitchRecoveryFixture.entry("c"), AccountSwitchRecoveryFixture.entry("b", token: "new-b")] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let record = try fixture.stageIntent()
            try fixture.switcher.applySharedAuthentication(entry, family: "claude")
            let before = try fixture.switcher.readClaudeSwitchState()
            let writesBefore = fixture.keychain.writeCount

            XCTAssertThrowsError(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: fixture.freshStore()))

            XCTAssertEqual(try fixture.journal.load(), record)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
            XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
            try fixture.assertSavedAccountsUnchanged()
        }
    }

    func testEveryPartialCredentialAndStateWriteKeepsReconciliationBlocked() async throws {
        for completedWrites in 1...4 {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let record = try fixture.stageIntent()
            fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
            if completedWrites >= 2 {
                fixture.keychain.currentUserValues[fixture.baseService] = fixture.entryB.credential
            }
            if completedWrites >= 3 {
                try Data(fixture.entryB.credential.utf8)
                    .write(to: fixture.root.appendingPathComponent(".claude/.credentials.json"))
            }
            if completedWrites >= 4 {
                let account = try XCTUnwrap(fixture.entryB.claudeOAuthAccount)
                try Data(#"{"oauthAccount":\#(account)}"#.utf8)
                    .write(to: fixture.root.appendingPathComponent(".claude.json"))
            }
            let before = try fixture.switcher.readClaudeSwitchState()
            let writesBefore = fixture.keychain.writeCount
            let reloaded = try fixture.freshStore()

            XCTAssertThrowsError(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded))
            do {
                _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)
                XCTFail("Credential and account state must name the same completed switch")
            } catch {}

            XCTAssertEqual(try fixture.journal.load(), record)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
            XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
            try fixture.assertSavedAccountsUnchanged()
        }
    }

    func testAnyMissingTargetSourceDoesNotCountAsCompletedSwitch() throws {
        for missingSource in 0..<5 {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let record = try fixture.stageIntent()
            try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
            switch missingSource {
            case 0: fixture.keychain.currentUserValues.removeValue(forKey: fixture.scopedService)
            case 1: fixture.keychain.currentUserValues.removeValue(forKey: fixture.baseService)
            default:
                let paths = [".claude/.credentials.json", ".claude.json", ".claude/.claude.json"]
                try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(paths[missingSource - 2]))
            }
            let before = try fixture.switcher.readClaudeSwitchState()
            let writesBefore = fixture.keychain.writeCount

            XCTAssertThrowsError(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: fixture.freshStore()))

            XCTAssertEqual(try fixture.journal.load(), record)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
            XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
            try fixture.assertSavedAccountsUnchanged()
        }
    }

    func testCorruptJournalAndKeychainReadFailureRemainBlocked() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        fixture.keychain.readFailureService = fixture.scopedService
        XCTAssertThrowsError(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: fixture.freshStore()))
        XCTAssertEqual(try fixture.journal.load(), record)
        fixture.keychain.readFailureService = nil
        try LocalTextFileAccessor().writeText(fixture.journal.path, "broken-journal")
        let writesBefore = fixture.keychain.writeCount

        XCTAssertThrowsError(try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: fixture.freshStore()))
        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store))

        XCTAssertEqual(try String(contentsOfFile: fixture.journal.path, encoding: .utf8), "broken-journal")
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testExplicitRetryKeepsOriginalDepartureProofAfterSelectionWasSaved() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { false })
        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store))
        let first = try XCTUnwrap(fixture.journal.load())
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryA.credential
        let c = try fixture.store.add(family: "claude", label: "C", identityKey: "acct-c|org-c", id: "profile-c")
        let entryC = AccountSwitchRecoveryFixture.entry("c")
        try fixture.switcher.saveSnapshot(entryC, for: c)
        try fixture.switcher.writeWorkspaceAuthentication(entryC, for: c)

        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: c, in: fixture.store))

        let retried = try XCTUnwrap(fixture.journal.load())
        XCTAssertNotEqual(retried.id, first.id)
        XCTAssertEqual(retried.previousProfileID, first.previousProfileID)
        XCTAssertEqual(retried.previousIdentity, first.previousIdentity)
        XCTAssertEqual(retried.previousCredentialFingerprint, first.previousCredentialFingerprint)
        XCTAssertEqual(retried.previousStateFingerprint, first.previousStateFingerprint)
        XCTAssertEqual(retried.priorSelectionIDs, [fixture.a.id, fixture.b.id])
        XCTAssertEqual(retried.selectedProfileID, c.id)
        let reloaded = try fixture.freshStore()
        reloaded.setPreferred(family: "claude", profileID: fixture.b.id)
        XCTAssertEqual(
            try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded),
            .updated(profileID: c.id)
        )
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testRepeatedRetriesRecoverFromAnEarlierPersistedSelection() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { false })
        XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store))
        let first = try XCTUnwrap(fixture.journal.load())
        var selected = fixture.b
        for suffix in ["c", "d"] {
            fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryA.credential
            selected = try fixture.store.add(
                family: "claude", label: suffix.uppercased(), identityKey: "acct-\(suffix)|org-\(suffix)",
                id: "profile-\(suffix)"
            )
            let entry = AccountSwitchRecoveryFixture.entry(suffix)
            try fixture.switcher.saveSnapshot(entry, for: selected)
            try fixture.switcher.writeWorkspaceAuthentication(entry, for: selected)
            XCTAssertThrowsError(try fixture.selectionSwitcher.switchAuthentication(to: selected, in: fixture.store))
        }
        let record = try XCTUnwrap(fixture.journal.load())
        XCTAssertEqual(record.previousStateFingerprint, first.previousStateFingerprint)
        XCTAssertEqual(record.priorSelectionIDs, ["profile-a", "profile-b", "profile-c"])
        let reloaded = try fixture.freshStore()
        reloaded.setPreferred(family: "claude", profileID: fixture.b.id)

        XCTAssertEqual(
            try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: reloaded),
            .updated(profileID: selected.id)
        )

        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testExplicitRetryCompletesAndClearsTheOriginalJournal() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let first = try fixture.stageIntent()
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(first.previousProfileID, fixture.a.id)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testRetryJournalFailureKeepsTheOriginalRecoveryProof() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
        let before = try fixture.switcher.readClaudeSwitchState()
        let files = SwitchJournalFiles()
        files.failWrite = true
        let service = AccountSelectionSwitcher(
            switcher: fixture.switcher, journal: AccountSwitchJournal(path: fixture.journal.path, files: files)
        )

        XCTAssertThrowsError(try service.switchAuthentication(to: fixture.b, in: fixture.store))

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testReselectingCurrentProfileDoesNotCreateARecoveryJournal() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let writesBefore = fixture.keychain.writeCount

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)

        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertNil(try fixture.journal.load())
    }

    func testUnreadableJournalBlocksRecoveryAndSwitchWithoutMutation() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        let files = SwitchJournalFiles()
        files.failRead = true
        let service = AccountSelectionSwitcher(
            switcher: fixture.switcher, journal: AccountSwitchJournal(path: fixture.journal.path, files: files)
        )
        let before = try fixture.switcher.readClaudeSwitchState()
        let writesBefore = fixture.keychain.writeCount

        XCTAssertThrowsError(try service.recoverInterruptedSwitch(in: fixture.store))
        XCTAssertThrowsError(try service.switchAuthentication(to: fixture.b, in: fixture.store))

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testJournalContainsOnlyIdentifiersAndFingerprints() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        let text = try String(contentsOfFile: fixture.journal.path, encoding: .utf8)

        XCTAssertTrue(text.contains(fixture.a.id))
        XCTAssertTrue(text.contains(fixture.b.id))
        XCTAssertFalse(text.contains("token-a"))
        XCTAssertFalse(text.contains("token-b"))
        XCTAssertFalse(text.contains("refreshToken"))
        XCTAssertFalse(text.contains("accessToken"))
    }
}
