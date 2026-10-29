import XCTest
@testable import OpenUsage

@MainActor
final class AccountSwitchRecoveryMutationTests: XCTestCase {
    func testExplicitRetryOfCurrentAccountClearsMixedSwitchAndAllowsReSignIn() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
        XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)

        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
        try fixture.assertSavedAccountsUnchanged()

        let fresh = AccountSwitchRecoveryFixture.entry("a", token: "fresh-sign-in-a")
        try fixture.switcher.writeWorkspaceAuthentication(fresh, for: fixture.a)
        let signedIn = try fixture.importer.completeReSignIn(
            profileID: fixture.a.id, in: fixture.store,
            isActive: fixture.store.preferredProfileID(family: "claude") == fixture.a.id
        )

        XCTAssertEqual(signedIn, fixture.a)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), fresh)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fresh)
        XCTAssertEqual(
            try fixture.importer.readWorkspaceCredential(family: "claude", profileID: fixture.a.id)?.entry,
            fresh
        )
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), fixture.entryB)
        XCTAssertEqual(
            try fixture.importer.readWorkspaceCredential(family: "claude", profileID: fixture.b.id)?.entry,
            fixture.entryB
        )
        XCTAssertEqual(try fixture.freshStore().profile(id: fixture.b.id), fixture.b)
    }

    func testReSignInDoesNotConsumeFreshWorkspaceWhileSwitchRecoveryIsPending() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let fresh = AccountSwitchRecoveryFixture.entry("c")
        try fixture.switcher.writeWorkspaceAuthentication(fresh, for: fixture.a)
        let writesBefore = fixture.keychain.writeCount

        XCTAssertThrowsError(try fixture.importer.completeReSignIn(
            profileID: fixture.a.id, in: fixture.store, isActive: true
        ))

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), fixture.entryA)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), fixture.entryB)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        XCTAssertEqual(
            try fixture.importer.readWorkspaceCredential(family: "claude", profileID: fixture.a.id)?.entry,
            fresh
        )
        XCTAssertEqual(try fixture.freshStore().profile(id: fixture.a.id), fixture.a)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
    }

    func testRemovingAnAccountDuringPartialSwitchPreservesItsSnapshotAndWorkspace() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
        let before = try fixture.switcher.readClaudeSwitchState()
        let writesBefore = fixture.keychain.writeCount

        XCTAssertThrowsError(try fixture.importer.removeAccount(fixture.b, from: fixture.store))

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testRemovalRecoversTargetSelectionBeforeRejectingRemovalOfThatAccount() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")

        XCTAssertThrowsError(try fixture.importer.removeAccount(fixture.b, from: fixture.store)) { error in
            XCTAssertEqual(error as? AccountProfileError, .removeSelectedProfile)
        }

        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testRemovingDepartedAccountFinishesRecoveryBeforeDeletingItsSavedAuthentication() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        fixture.store.setPreferred(family: "claude", profileID: fixture.b.id)

        try fixture.importer.removeAccount(fixture.a, from: fixture.store)

        XCTAssertNil(try fixture.journal.load())
        XCTAssertNil(try fixture.freshStore().profile(id: fixture.a.id))
        XCTAssertNil(try fixture.switcher.loadSnapshot(for: fixture.a))
        XCTAssertEqual(try fixture.freshStore().profile(id: fixture.b.id), fixture.b)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), fixture.entryB)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        XCTAssertEqual(
            try fixture.importer.reconcileSelectedClaudeSharedAuthentication(in: fixture.store),
            .unchanged
        )
    }

    func testStartupRecoveryRejectsObservationAfterSelectionChanges() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let started = expectation(description: "switch recovery read started")
        let gate = SwitchRecoveryReadGate(started: started)
        let scoped = fixture.scopedService
        fixture.keychain.beforeRead = { service in
            if service == scoped { try gate.pauseOnce() }
        }
        defer { gate.release() }
        let writesBefore = fixture.keychain.writeCount
        let recovery = Task { try await fixture.selectionSwitcher.recoverInterruptedSwitchAfterStartup(in: fixture.store) }
        await fulfillment(of: [started], timeout: 3)

        fixture.store.setPreferred(family: "claude", profileID: fixture.b.id)
        gate.release()
        do {
            _ = try await recovery.value
            XCTFail("An observation from the previous selection must not finish recovery")
        } catch {}
        fixture.keychain.beforeRead = nil

        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testStartupRecoveryDoesNotClearAReplacementJournal() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let started = expectation(description: "switch recovery read started")
        let gate = SwitchRecoveryReadGate(started: started)
        let scoped = fixture.scopedService
        fixture.keychain.beforeRead = { service in
            if service == scoped { try gate.pauseOnce() }
        }
        defer { gate.release() }
        let writesBefore = fixture.keychain.writeCount
        let recovery = Task { try await fixture.selectionSwitcher.recoverInterruptedSwitchAfterStartup(in: fixture.store) }
        await fulfillment(of: [started], timeout: 3)

        var replacement = record
        replacement.id = UUID()
        try fixture.journal.save(replacement, replacing: record)
        gate.release()
        do {
            _ = try await recovery.value
            XCTFail("A stale recovery must not finish a different switch journal")
        } catch {}
        fixture.keychain.beforeRead = nil

        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.journal.load(), replacement)
        XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testUserSwitchObservationsLeaveMainActorResponsive() async throws {
        for phase in ["preflight", "applied", "pendingRecovery"] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            if phase == "pendingRecovery" {
                _ = try fixture.stageIntent()
                try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
            }
            let started = expectation(description: "\(phase) observation started")
            let responsive = expectation(description: "MainActor responds during \(phase)")
            let gate = SwitchRecoveryReadGate(started: started)
            let keychain = fixture.keychain
            let base = fixture.baseService
            let target = fixture.entryB.credential
            keychain.beforeRead = { service in
                if service == base, phase != "applied" || keychain.currentUserValues[base] == target {
                    try gate.pauseOnce()
                }
            }
            defer {
                gate.release()
                keychain.beforeRead = nil
            }
            let operation = Task {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }
            await fulfillment(of: [started], timeout: 3)
            let heartbeat = Task { @MainActor in
                responsive.fulfill()
                gate.release()
            }
            await fulfillment(of: [responsive], timeout: 1)
            await heartbeat.value
            try await operation.value

            XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
            XCTAssertNil(try fixture.journal.load())
            try fixture.assertSavedAccountsUnchanged()
        }
    }

    func testPreflightObservationRejectsConcurrentAccountChangesBeforeWriting() async throws {
        for mutation in ["profile", "preferred", "revision", "identityTransaction", "journal"] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let started = expectation(description: "preflight observation before \(mutation)")
            let gate = SwitchRecoveryReadGate(started: started)
            let base = fixture.baseService
            fixture.keychain.beforeRead = { service in
                if service == base { try gate.pauseOnce() }
            }
            defer {
                gate.release()
                fixture.keychain.beforeRead = nil
            }
            let writesBefore = fixture.keychain.writeCount
            let operation = Task {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }
            await fulfillment(of: [started], timeout: 3)
            var expectedJournal: AccountSwitchJournal.Record?
            var expectedIdentityTransaction: AccountIdentityReplacement?
            do {
                switch mutation {
                case "profile":
                    try fixture.store.rename(profileID: fixture.b.id, to: "Renamed B")
                case "preferred":
                    fixture.store.setPreferred(family: "claude", profileID: fixture.b.id)
                case "revision", "identityTransaction":
                    let transaction = try fixture.store.beginIdentityReplacement(
                        profileID: fixture.b.id, with: fixture.b.identityKey, replacesSharedAuthentication: false
                    )
                    if mutation == "revision" {
                        try fixture.store.commitIdentityReplacement(transaction)
                    } else {
                        expectedIdentityTransaction = transaction
                    }
                default:
                    expectedJournal = try fixture.stageIntent()
                }
            } catch {
                gate.release()
                _ = await operation.result
                throw error
            }
            let expectedProfiles = fixture.store.profiles
            let expectedPreferred = fixture.store.preferredProfileID(family: "claude")
            let expectedRevision = fixture.store.authenticationRevision
            gate.release()
            await assertSwitchFails { try await operation.value }
            fixture.keychain.beforeRead = nil

            XCTAssertEqual(fixture.keychain.writeCount, writesBefore, mutation)
            XCTAssertEqual(fixture.store.profiles, expectedProfiles, mutation)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), expectedPreferred, mutation)
            XCTAssertEqual(fixture.store.authenticationRevision, expectedRevision, mutation)
            XCTAssertEqual(try fixture.journal.load(), expectedJournal, mutation)
            XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), expectedIdentityTransaction, mutation)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA, mutation)
            try fixture.assertSavedAccountsUnchanged()
        }
    }

    func testAppliedObservationPreservesReplacementJournalAndOldSelection() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let started = expectation(description: "applied observation started")
        let gate = blockAppliedObservation(in: fixture, started: started)
        defer {
            gate.release()
            fixture.keychain.beforeRead = nil
        }
        let operation = Task {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }
        await fulfillment(of: [started], timeout: 3)
        let replacement: AccountSwitchJournal.Record
        do {
            let original = try XCTUnwrap(fixture.journal.load())
            var changed = original
            changed.id = UUID()
            try fixture.journal.save(changed, replacing: original)
            replacement = changed
        } catch {
            gate.release()
            _ = await operation.result
            throw error
        }
        let writesBeforeResume = fixture.keychain.writeCount
        gate.release()
        await assertSwitchFails { try await operation.value }
        fixture.keychain.beforeRead = nil

        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.journal.load(), replacement)
        XCTAssertEqual(fixture.keychain.writeCount, writesBeforeResume)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testCancellationDuringAppliedObservationKeepsRecoveryJournal() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let started = expectation(description: "applied observation before cancellation")
        let gate = blockAppliedObservation(in: fixture, started: started)
        defer {
            gate.release()
            fixture.keychain.beforeRead = nil
        }
        let operation = Task {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }
        await fulfillment(of: [started], timeout: 3)
        operation.cancel()
        gate.release()
        do {
            try await operation.value
            XCTFail("Cancellation must retain the switch journal before selection commit")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        fixture.keychain.beforeRead = nil

        let record = try XCTUnwrap(fixture.journal.load())
        XCTAssertEqual(record.previousProfileID, fixture.a.id)
        XCTAssertEqual(record.selectedProfileID, fixture.b.id)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        try fixture.assertSavedAccountsUnchanged()
    }

    private func blockAppliedObservation(
        in fixture: AccountSwitchRecoveryFixture,
        started: XCTestExpectation
    ) -> SwitchRecoveryReadGate {
        let gate = SwitchRecoveryReadGate(started: started)
        let keychain = fixture.keychain
        let base = fixture.baseService
        let target = fixture.entryB.credential
        keychain.beforeRead = { service in
            if service == base, keychain.currentUserValues[base] == target { try gate.pauseOnce() }
        }
        return gate
    }
}
