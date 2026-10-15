import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AccountInteractiveMutationTests: XCTestCase {
    private var root: URL!
    private var store: AccountProfilesStore!
    private var keychain: ApprovalProgressKeychain!
    private var workspace: AccountSignInWorkspace!
    private var switcher: AccountCredentialSwitcher!
    private var importer: AccountCredentialImporter!

    override func setUp() async throws {
        try await super.setUp()
        let suite = "AccountInteractiveMutationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = AccountProfilesStore(defaults: defaults)
        keychain = ApprovalProgressKeychain()
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
        switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        addTeardownBlock { [root] in
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root!)
        }
    }

    func testSwitchApprovalReadsAndWritesAllowMainActorWorkToProgress() async throws {
        let current = try store.add(family: "codex", label: "Current", identityKey: "current", id: "current")
        let target = try store.add(family: "codex", label: "Target", identityKey: "target", id: "target")
        let currentEntry = entry(account: "current", token: "current-token")
        let targetEntry = entry(account: "target", token: "target-token")
        try switcher.saveSnapshot(currentEntry, for: current)
        try switcher.saveSnapshot(targetEntry, for: target)
        try switcher.applySharedAuthentication(currentEntry, family: "codex")
        keychain.startRecording()

        try await performSwitch(to: target)

        assertApprovalProgress()
        XCTAssertEqual(store.preferredProfileID(family: "codex"), target.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), targetEntry)
    }

    func testReSignInApprovalReadsAndWritesAllowMainActorWorkToProgress() async throws {
        let profile = try store.add(family: "codex", label: "Personal", identityKey: "previous", id: "personal")
        let previous = entry(account: "previous", token: "previous-token")
        let replacement = entry(account: "replacement", token: "replacement-token")
        try switcher.saveSnapshot(previous, for: profile)
        try switcher.applySharedAuthentication(previous, family: "codex")
        try switcher.writeWorkspaceAuthentication(replacement, for: profile)
        keychain.startRecording()

        let rebound = try await performReSignIn(profileID: profile.id)

        assertApprovalProgress()
        XCTAssertEqual(rebound.id, profile.id)
        XCTAssertEqual(rebound.label, profile.label)
        XCTAssertEqual(rebound.identityKey, "replacement")
        XCTAssertEqual(store.preferredProfileID(family: "codex"), profile.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), replacement)
    }

    func testInteractiveSwitchPreservesUnsynchronizedCodexRotationAndClearsSelectedMarkers() async throws {
        let current = try store.add(family: "codex", label: "Current", identityKey: "current", id: "current")
        let target = try store.add(family: "codex", label: "Target", identityKey: "target", id: "target")
        let staleShared = entry(account: "current", token: "stale-current")
        var rotated = entry(account: "current", token: "rotated-current")
        rotated.codexStaleSharedCredentialFingerprints = [CodexAuthStore.credentialFingerprint(staleShared.credential)]
        var targetEntry = entry(account: "target", token: "rotated-target")
        targetEntry.codexStaleSharedCredentialFingerprints = ["stale-target"]
        try switcher.saveSnapshot(rotated, for: current)
        try switcher.saveSnapshot(targetEntry, for: target)
        try switcher.applySharedAuthentication(staleShared, family: "codex")
        keychain.startRecording()

        try await performSwitch(to: target)

        assertApprovalProgress()
        keychain.stopRecording()
        XCTAssertEqual(store.preferredProfileID(family: "codex"), target.id)
        XCTAssertEqual(try switcher.loadSnapshot(for: current), rotated)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: current.id)?.entry.credential,
                       rotated.credential)
        targetEntry.codexStaleSharedCredentialFingerprints = nil
        XCTAssertEqual(try switcher.loadSnapshot(for: target), targetEntry)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), targetEntry)
    }

    func testSameAccountSwitchDoesNotReadOrWriteCredentials() async throws {
        let current = try store.add(family: "codex", label: "Current", identityKey: "current", id: "current")
        let revision = AccountCredentialMutationLock.revision
        keychain.startRecording()

        try await performSwitch(to: current)

        XCTAssertTrue(keychain.observations.isEmpty)
        XCTAssertEqual(AccountCredentialMutationLock.revision, revision)
        XCTAssertFalse(store.isAuthenticationMutationInProgress)
    }

    func testAsyncSelectionPersistenceFailureKeepsJournalUntilStartupRecoveryCommits() async throws {
        let suite = "AccountInteractiveSelectionFailure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(InteractiveSelectionFailureDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let selectedStore = AccountProfilesStore(defaults: defaults)
        let current = try selectedStore.add(family: "codex", label: "Current", identityKey: "current", id: "current")
        let target = try selectedStore.add(family: "codex", label: "Target", identityKey: "target", id: "target")
        let currentEntry = entry(account: "current", token: "current-token")
        let targetEntry = entry(account: "target", token: "target-token")
        try switcher.saveSnapshot(currentEntry, for: current)
        try switcher.saveSnapshot(targetEntry, for: target)
        try switcher.applySharedAuthentication(currentEntry, family: "codex")
        defaults.rejectNextWriteForKey = AccountProfilesStore.storageKey
        keychain.startRecording()

        do {
            try await switcher.switchAuthentication(to: target, in: selectedStore)
            XCTFail("Expected the selection persistence failure")
        } catch {
            guard case AccountIdentityReplacementError.invalidTransaction = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        assertApprovalProgress()
        keychain.stopRecording()
        XCTAssertFalse(selectedStore.isAuthenticationMutationInProgress)
        XCTAssertEqual(selectedStore.preferredProfileID(family: "codex"), current.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), targetEntry)
        let pending = try XCTUnwrap(switcher.switchJournal.load())
        XCTAssertEqual(pending.targetSnapshotDigest, try targetEntry.snapshotDigest())
        XCTAssertTrue(try switcher.credentialArtifacts.matches(pending.applied))
        let restarted = AccountProfilesStore(defaults: defaults)
        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), current.id)
        keychain.startRecording()

        let recovered = try await switcher.recoverInterruptedSwitchAfterStartup(in: restarted)

        XCTAssertTrue(recovered)
        XCTAssertTrue(keychain.observations.allSatisfy { !$0.wasOnMainThread && $0.mainActorProgressed })
        keychain.stopRecording()
        XCTAssertEqual(restarted.preferredProfileID(family: "codex"), target.id)
        XCTAssertEqual(AccountProfilesStore(defaults: defaults).preferredProfileID(family: "codex"), target.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), targetEntry)
        XCTAssertNil(try switcher.switchJournal.load())
        XCTAssertFalse(restarted.isAuthenticationMutationInProgress)
    }

    func testNoPendingSwitchRecoveryDoesNotBeginAuthenticationMutation() async throws {
        var starts = 0
        var finishes = 0
        store.onAuthenticationMutationStarted = { starts += 1 }
        store.onAuthenticationMutationWillEnd = { _ in finishes += 1 }

        let recovered = try await switcher.recoverInterruptedSwitchAfterStartup(in: store)

        XCTAssertFalse(recovered)
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(finishes, 0)
        XCTAssertFalse(store.isAuthenticationMutationInProgress)
    }

    func testRecoveryRevisionCheckKeepsMainActorResponsiveWhileCredentialLockIsHeld() async throws {
        let revision = AccountCredentialMutationLock.revision
        let gate = MutationKeychainGate()
        defer { gate.release() }
        let worker = Task.detached {
            try AccountCredentialMutation.withLock { try gate.pause() }
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        var committed = false
        let started = Date()

        let accepted = AccountCredentialMutationLock.withUnchangedRevisionIfAvailable(revision) {
            committed = true
        }
        let elapsed = Date().timeIntervalSince(started)
        let heartbeat = Task { @MainActor in true }
        let mainActorProgressed = await heartbeat.value

        XCTAssertFalse(accepted)
        XCTAssertFalse(committed)
        XCTAssertLessThan(elapsed, 0.5)
        XCTAssertTrue(mainActorProgressed)
        gate.release()
        try await worker.value
    }

    func testNoPendingStartupProbeDoesNotBlockExplicitMutationRecovery() async throws {
        let gatedKeychain = GatedMutationKeychain()
        let recoverySwitcher = AccountCredentialSwitcher(
            keychain: gatedKeychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        let gate = gatedKeychain.gateNext(.read, service: AccountSwitchJournal.service)
        defer { gate.release() }
        let startup = Task {
            try await recoverySwitcher.recoverInterruptedSwitchAfterStartup(in: store)
        }
        await fulfillment(of: [gate.entered], timeout: 5)
        let mutation = try store.beginAuthenticationMutation()
        defer { store.endAuthenticationMutation(mutation) }

        let explicitRecovery = try await recoverySwitcher.recoverInterruptedSwitchAfterStartup(
            in: store, allowInteraction: true, mutation: mutation
        )
        gate.release()
        let startupRecovery = try await startup.value

        XCTAssertFalse(explicitRecovery)
        XCTAssertFalse(startupRecovery)
        XCTAssertTrue(store.isAuthenticationMutationInProgress)
    }

    func testPendingClaudeRecoveryReadsAndWritesAllowMainActorWorkToProgress() async throws {
        let previous = claudeEntry(account: "previous")
        let replacement = claudeEntry(account: "replacement")
        let previousIdentity = try XCTUnwrap(switcher.identity(of: previous, family: "claude")?.identityKey)
        let replacementIdentity = try XCTUnwrap(switcher.identity(of: replacement, family: "claude")?.identityKey)
        let profile = try store.add(family: "claude", label: "Personal", identityKey: previousIdentity, id: "personal")
        try switcher.saveSnapshot(replacement, for: profile)
        try switcher.applySharedAuthentication(previous, family: "claude")
        try switcher.writeWorkspaceAuthentication(replacement, for: profile)
        _ = try store.beginIdentityReplacement(
            profileID: profile.id, with: replacementIdentity, replacesSharedAuthentication: true
        )
        keychain.startRecording()

        let rebound = try await performReSignIn(profileID: profile.id)

        assertApprovalProgress()
        keychain.stopRecording()
        XCTAssertEqual(rebound.id, profile.id)
        XCTAssertEqual(rebound.identityKey, replacementIdentity)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
        XCTAssertEqual(try switcher.loadSnapshot(for: rebound), replacement)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "claude"), replacement)
        XCTAssertNil(try store.pendingIdentityReplacement())
    }

    private func performSwitch(to profile: AccountProfile) async throws {
        try await switcher.switchAuthentication(to: profile, in: store)
    }

    private func performReSignIn(profileID: String) async throws -> AccountProfile {
        try await importer.completeReSignInAfterLogin(profileID: profileID, in: store)
    }

    private func assertApprovalProgress(file: StaticString = #filePath, line: UInt = #line) {
        let observations = keychain.observations
        XCTAssertTrue(observations.contains { $0.operation == "read" }, file: file, line: line)
        XCTAssertTrue(observations.contains { $0.operation == "write" }, file: file, line: line)
        XCTAssertTrue(observations.allSatisfy { !$0.wasOnMainThread }, file: file, line: line)
        XCTAssertTrue(observations.allSatisfy(\.mainActorProgressed), file: file, line: line)
    }

    private func entry(account: String, token: String) -> AccountCredentialVault.Entry {
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

private final class InteractiveSelectionFailureDefaults: UserDefaults {
    var rejectNextWriteForKey: String?

    override func set(_ value: Any?, forKey defaultName: String) {
        if rejectNextWriteForKey == defaultName {
            rejectNextWriteForKey = nil
            return
        }
        super.set(value, forKey: defaultName)
    }
}

private final class ApprovalProgressKeychain: KeychainAccessing, @unchecked Sendable {
    struct Observation {
        var operation: String
        var wasOnMainThread: Bool
        var mainActorProgressed: Bool
    }

    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var isRecording = false
    private var recorded: [Observation] = []

    var observations: [Observation] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func startRecording() {
        lock.lock()
        isRecording = true
        lock.unlock()
    }

    func stopRecording() {
        lock.lock()
        isRecording = false
        lock.unlock()
    }

    func readGenericPassword(service: String) throws -> String? {
        record(operation: "read")
        lock.lock()
        defer { lock.unlock() }
        return values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        record(operation: "write")
        lock.lock()
        values[service] = value
        lock.unlock()
    }

    func deleteGenericPassword(service: String) throws {
        lock.lock()
        values.removeValue(forKey: service)
        lock.unlock()
    }

    private func record(operation: String) {
        lock.lock()
        let shouldRecord = isRecording
        lock.unlock()
        guard shouldRecord else { return }
        let progress = DispatchSemaphore(value: 0)
        Task { @MainActor in progress.signal() }
        let observation = Observation(
            operation: operation,
            wasOnMainThread: Thread.isMainThread,
            mainActorProgressed: progress.wait(timeout: .now() + 0.5) == .success
        )
        lock.lock()
        recorded.append(observation)
        lock.unlock()
    }
}
