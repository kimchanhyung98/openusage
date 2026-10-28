import XCTest
@testable import OpenUsage

@MainActor
final class AccountSwitchRecoveryMutationTests: XCTestCase {
    func testExplicitRetryOfCurrentAccountClearsMixedSwitchAndAllowsReSignIn() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
        XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)

        try fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)

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
}
