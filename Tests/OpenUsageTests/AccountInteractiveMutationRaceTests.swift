import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AccountInteractiveMutationRaceTests: XCTestCase {
    private var root: URL!
    private var store: AccountProfilesStore!
    private var keychain: GatedMutationKeychain!
    private var fileManager: GatedMutationFileManager!
    private var workspace: AccountSignInWorkspace!
    private var switcher: AccountCredentialSwitcher!
    private var importer: AccountCredentialImporter!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "AccountInteractiveMutationRaceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AccountProfilesStore(defaults: defaults)
        keychain = GatedMutationKeychain()
        fileManager = GatedMutationFileManager()
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
        switcher = AccountCredentialSwitcher(
            keychain: keychain, fileManager: fileManager,
            environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        importer = AccountCredentialImporter(
            keychain: keychain, fileManager: fileManager,
            environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        addTeardownBlock { [root] in
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root!)
        }
    }

    func testAlreadyCancelledSwitchDoesNotReadKeychain() async throws {
        let fixture = try seedAccounts()
        keychain.startRecording()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await switcher.switchAuthentication(to: fixture.target, in: store)
        }

        do {
            try await task.value
            XCTFail("Expected cancellation before Keychain access")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(keychain.observations.isEmpty)
        try assertCurrentAuthentication(fixture)
        XCTAssertFalse(store.isAuthenticationMutationInProgress)
    }

    func testStandaloneSnapshotApprovalDoesNotHoldCredentialMutationLock() async throws {
        let fixture = try seedAccounts()
        let gate = keychain.gateNext(.read, service: snapshotService(fixture.target))
        defer { gate.release() }
        let switcher = self.switcher!
        let read = Task.detached {
            try switcher.loadSnapshot(for: fixture.target, allowInteraction: true)
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let acquired = expectation(description: "Credential mutation lock remains available")
        let mutation = Task.detached {
            AccountCredentialMutationLock.acquire()
            defer { AccountCredentialMutationLock.release() }
            acquired.fulfill()
        }

        await fulfillment(of: [acquired], timeout: 1)

        gate.release()
        _ = try await read.value
        await mutation.value
    }

    func testAlreadyCancelledReSignInDoesNotReadKeychain() async throws {
        let fixture = try seedAccounts()
        try switcher.writeWorkspaceAuthentication(fixture.targetEntry, for: fixture.current)
        keychain.startRecording()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await importer.completeReSignInAfterLogin(profileID: fixture.current.id, in: store)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before Keychain access")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(keychain.observations.isEmpty)
        try assertCurrentAuthentication(fixture)
        XCTAssertNil(try store.pendingIdentityReplacement())
        XCTAssertFalse(store.isAuthenticationMutationInProgress)
    }

    func testCancellationDuringSnapshotApprovalLeavesAuthenticationUnchanged() async throws {
        let fixture = try seedAccounts()
        let gate = keychain.gateNext(.read, service: snapshotService(fixture.target))
        defer { gate.release() }
        keychain.startRecording()
        let task = beginSwitch(to: fixture.target)
        await fulfillment(of: [gate.entered], timeout: 5)

        task.cancel()
        gate.release()
        do {
            try await task.value
            XCTFail("Expected cancellation before authentication writes")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertTrue(keychain.observations.allSatisfy { $0.operation == .read })
        try assertCurrentAuthentication(fixture)
        XCTAssertNil(try store.pendingIdentityReplacement())
        try await switcher.switchAuthentication(to: fixture.target, in: store)
        XCTAssertEqual(store.preferredProfileID(family: "codex"), fixture.target.id)
    }

    func testTargetIdentityABAChangeDuringApprovalRejectsPreparedSwitch() async throws {
        let fixture = try seedAccounts()
        let gate = keychain.gateNext(.read, service: snapshotService(fixture.target))
        defer { gate.release() }
        keychain.startRecording()
        let task = beginSwitch(to: fixture.target)
        await fulfillment(of: [gate.entered], timeout: 5)

        _ = try store.replaceIdentity(profileID: fixture.target.id, with: "temporary-identity")
        _ = try store.replaceIdentity(profileID: fixture.target.id, with: fixture.target.identityKey)
        gate.release()
        await assertMutationFailure(task, expected: .changed)

        XCTAssertTrue(keychain.observations.allSatisfy { $0.operation == .read })
        XCTAssertEqual(store.profile(id: fixture.target.id)?.identityKey, fixture.target.identityKey)
        try assertCurrentAuthentication(fixture)
    }

    func testPreferredSelectionABAChangeDuringApprovalRejectsPreparedSwitch() async throws {
        let fixture = try seedAccounts()
        let gate = keychain.gateNext(.read, service: snapshotService(fixture.target))
        defer { gate.release() }
        keychain.startRecording()
        let task = beginSwitch(to: fixture.target)
        await fulfillment(of: [gate.entered], timeout: 5)

        store.setPreferred(family: "codex", profileID: fixture.target.id)
        store.setPreferred(family: "codex", profileID: fixture.current.id)
        gate.release()
        await assertMutationFailure(task, expected: .changed)

        XCTAssertTrue(keychain.observations.allSatisfy { $0.operation == .read })
        try assertCurrentAuthentication(fixture)
    }

    func testSnapshotRotationDuringApprovalRejectsCapturedOldCredential() async throws {
        let fixture = try seedAccounts()
        let service = snapshotService(fixture.target)
        let keychain = self.keychain!
        let sharedAuth = URL(fileURLWithPath: switcher.sharedHomePath(family: "codex"))
            .appendingPathComponent("auth.json")
        let gate = fileManager.gateNextFileExists(atPath: sharedAuth.path) {
            keychain.hasRead(service: service)
        }
        defer { gate.release() }
        keychain.startRecording()
        let task = beginSwitch(to: fixture.target)
        await fulfillment(of: [gate.entered], timeout: 5)

        let rotated = codexEntry(account: fixture.target.identityKey, token: "rotated-target-token")
        try switcher.saveSnapshot(rotated, for: fixture.target)
        gate.release()
        await assertMutationFailure(task, expected: .changed)

        let mutations = keychain.observations.filter { $0.operation != .read }
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.operation, .write)
        XCTAssertEqual(mutations.first?.service, service)
        XCTAssertEqual(try switcher.loadSnapshot(for: fixture.target), rotated)
        try assertCurrentAuthentication(fixture)
    }

    func testCancelledLoginCleanupDoesNotBlockMainActorDuringSwitchApproval() async throws {
        let fixture = try seedAccounts()
        let stagedID = "cancelled-login"
        let stagedDirectory = try workspace.prepare(family: "codex", profileID: stagedID)
        let gate = keychain.gateNext(.write, service: snapshotService(fixture.current))
        defer { gate.release() }
        let switching = beginSwitch(to: fixture.target)
        await fulfillment(of: [gate.entered], timeout: 5)

        let cleanupStarted = expectation(description: "Cancelled login cleanup started")
        let cleanup = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            cleanupStarted.fulfill()
            try await importer.removeSignInWorkspaceAfterLogin(family: "codex", profileID: stagedID)
        }
        await fulfillment(of: [cleanupStarted], timeout: 1)
        let heartbeat = expectation(description: "MainActor remains available during cleanup")
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedDirectory.path))

        gate.release()
        try await switching.value
        try await cleanup.value

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
        XCTAssertEqual(store.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), fixture.targetEntry)
    }

    func testDuplicateSwitchAndReSignInAreRejectedWhileApprovalIsPending() async throws {
        let fixture = try seedAccounts()
        try switcher.writeWorkspaceAuthentication(fixture.targetEntry, for: fixture.target)
        let gate = keychain.gateNext(.read, service: snapshotService(fixture.target))
        defer { gate.release() }
        keychain.startRecording()
        let task = beginSwitch(to: fixture.target)
        await fulfillment(of: [gate.entered], timeout: 5)

        do {
            try await switcher.switchAuthentication(to: fixture.target, in: store)
            XCTFail("Expected the duplicate switch to be rejected")
        } catch {
            XCTAssertEqual(error as? AccountAuthenticationMutationError, .busy)
        }
        do {
            _ = try await importer.completeReSignInAfterLogin(profileID: fixture.target.id, in: store)
            XCTFail("Expected overlapping re-sign-in to be rejected")
        } catch {
            XCTAssertEqual(error as? AccountAuthenticationMutationError, .busy)
        }
        XCTAssertTrue(keychain.observations.allSatisfy { $0.operation == .read })
        gate.release()
        try await task.value

        XCTAssertEqual(store.preferredProfileID(family: "codex"), fixture.target.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), fixture.targetEntry)
        XCTAssertNil(try store.pendingIdentityReplacement())
    }

    func testCancellationAfterReSignInApplyBeginsStillCommitsIdentity() async throws {
        let fixture = try seedAccounts()
        let replacement = codexEntry(account: "replacement", token: "replacement-token")
        try switcher.writeWorkspaceAuthentication(replacement, for: fixture.current)
        let gate = keychain.gateNext(.write, service: snapshotService(fixture.current))
        defer { gate.release() }
        let task = Task {
            try await importer.completeReSignInAfterLogin(profileID: fixture.current.id, in: store)
        }
        await fulfillment(of: [gate.entered], timeout: 5)

        store.setPreferred(family: "codex", profileID: fixture.target.id)
        XCTAssertEqual(store.preferredProfileID(family: "codex"), fixture.current.id)
        try store.rename(profileID: fixture.current.id, to: "Renamed")
        XCTAssertThrowsError(try store.replaceIdentity(profileID: fixture.current.id, with: "blocked")) { error in
            XCTAssertEqual(error as? AccountAuthenticationMutationError, .busy)
        }
        task.cancel()
        gate.release()
        let rebound = try await task.value

        XCTAssertEqual(rebound.id, fixture.current.id)
        XCTAssertEqual(rebound.label, "Renamed")
        XCTAssertEqual(rebound.identityKey, "replacement")
        XCTAssertEqual(store.profile(id: fixture.current.id)?.identityKey, "replacement")
        XCTAssertEqual(store.preferredProfileID(family: "codex"), fixture.current.id)
        XCTAssertEqual(try switcher.loadSnapshot(for: rebound), replacement)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), replacement)
        XCTAssertNil(try store.pendingIdentityReplacement())
    }

    func testPartialClaudeApplyRollsBackOffMainActor() async throws {
        let fixture = try seedAccounts(family: "claude")
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: switcher.sharedHomePath(family: "claude"), environment: FakeEnvironment()
        )
        keychain.failNextWrite(service: baseService)
        keychain.startRecording(checkMainActorProgress: true)

        do {
            try await switcher.switchAuthentication(to: fixture.target, in: store)
            XCTFail("Expected the shared credential write to fail")
        } catch {
            XCTAssertEqual(error as? MutationKeychainError, .injectedWrite)
        }

        let observations = keychain.observations
        let sharedWrites = observations.filter {
            $0.operation == .write && ($0.service == scopedService || $0.service == baseService)
        }
        XCTAssertEqual(sharedWrites.map(\.service), [scopedService, baseService, scopedService])
        XCTAssertEqual(sharedWrites.map(\.value), [
            fixture.targetEntry.credential, fixture.targetEntry.credential,
            fixture.currentEntry.credential,
        ])
        XCTAssertTrue(observations.allSatisfy { !$0.wasOnMainThread })
        XCTAssertTrue(observations.allSatisfy(\.mainActorProgressed))
        keychain.stopRecording()
        try assertCurrentAuthentication(fixture)
        XCTAssertEqual(try keychain.readGenericPassword(service: baseService), fixture.currentEntry.credential)
        XCTAssertNil(try switcher.switchJournal.load())
        XCTAssertEqual(try switcher.loadSnapshot(for: fixture.current), fixture.currentEntry)
        XCTAssertEqual(try switcher.loadSnapshot(for: fixture.target), fixture.targetEntry)
        XCTAssertNil(try store.pendingIdentityReplacement())
    }

    private struct Fixture {
        var current: AccountProfile
        var target: AccountProfile
        var currentEntry: AccountCredentialVault.Entry
        var targetEntry: AccountCredentialVault.Entry
    }

    private func seedAccounts(family: String = "codex") throws -> Fixture {
        let currentEntry = family == "codex"
            ? codexEntry(account: "current", token: "current-token") : claudeEntry(account: "current")
        let targetEntry = family == "codex"
            ? codexEntry(account: "target", token: "target-token") : claudeEntry(account: "target")
        let currentIdentity = try XCTUnwrap(switcher.identity(of: currentEntry, family: family)?.identityKey)
        let targetIdentity = try XCTUnwrap(switcher.identity(of: targetEntry, family: family)?.identityKey)
        let current = try store.add(family: family, label: "Current", identityKey: currentIdentity, id: "current")
        let target = try store.add(family: family, label: "Target", identityKey: targetIdentity, id: "target")
        try switcher.saveSnapshot(currentEntry, for: current)
        try switcher.saveSnapshot(targetEntry, for: target)
        try switcher.applySharedAuthentication(currentEntry, family: family)
        return Fixture(current: current, target: target, currentEntry: currentEntry, targetEntry: targetEntry)
    }

    private func beginSwitch(to profile: AccountProfile) -> Task<Void, Error> {
        Task { try await switcher.switchAuthentication(to: profile, in: store) }
    }

    private func assertMutationFailure(
        _ task: Task<Void, Error>, expected: AccountAuthenticationMutationError,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await task.value
            XCTFail("Expected the prepared mutation to be rejected", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? AccountAuthenticationMutationError, expected, file: file, line: line)
        }
    }

    private func assertCurrentAuthentication(
        _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(
            store.preferredProfileID(family: fixture.current.family), fixture.current.id, file: file, line: line
        )
        XCTAssertEqual(
            try switcher.readSharedAuthentication(family: fixture.current.family), fixture.currentEntry,
            file: file, line: line
        )
    }

    private func snapshotService(_ profile: AccountProfile) -> String {
        AccountCredentialVault.service(family: profile.family, profileID: profile.id)
    }

    private func codexEntry(account: String, token: String) -> AccountCredentialVault.Entry {
        .init(
            credential: #"{"tokens":{"access_token":"\#(token)","account_id":"\#(account)"}}"#,
            claudeOAuthAccount: nil
        )
    }

    private func claudeEntry(account: String) -> AccountCredentialVault.Entry {
        .init(
            credential: #"{"claudeAiOauth":{"accessToken":"\#(account)-token","refreshToken":"\#(account)-refresh"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
        )
    }
}
