import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class ICloudUsageSyncIdentityPreparationTests: XCTestCase {
    private let enabledKey = "openusage.icloudSync.enabled.v1"
    private let deviceIDKey = "openusage.icloudSync.deviceID.v1"
    private let pendingDeletionKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"
    private let pendingIdentityDeletionKey = "openusage.icloudSync.pendingIdentityDeletion.v1"

    func testIdentityPreparationLeavesMainActorResponsiveAndUsesOnlyResolvedID() async throws {
        let defaults = makeDefaults()
        let cachedID = UUID().uuidString.lowercased()
        let stableID = UUID().uuidString.lowercased()
        defaults.set(cachedID, forKey: deviceIDKey)
        defaults.set(true, forKey: enabledKey)
        let identity = BlockingIdentityStore(storedID: stableID)
        defer { identity.release() }
        let history = IdentityPreparationHistoryStore()
        let started = ContinuousClock.now

        let sync = makeSync(defaults: defaults, identity: identity, history: history)

        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(1))
        try await waitUntil { identity.readStarted }
        let heartbeat = Task { @MainActor in true }
        let heartbeatFinished = await heartbeat.value
        XCTAssertTrue(heartbeatFinished)
        XCTAssertFalse(sync.isIdentityReady)
        XCTAssertEqual(identity.readWasOnMainThread, false)
        XCTAssertEqual(defaults.string(forKey: deviceIDKey), cachedID)
        sync.scheduleWrite()
        try await assertNoCloudIO(history)

        identity.release()
        try await waitUntil {
            let state = await history.snapshot()
            return sync.isIdentityReady && !state.writtenIDs.isEmpty && !sync.isSyncing
        }

        let state = await history.snapshot()
        XCTAssertEqual(sync.deviceID, stableID)
        XCTAssertEqual(defaults.string(forKey: deviceIDKey), stableID)
        XCTAssertTrue(state.writtenIDs.allSatisfy { $0 == stableID })
        XCTAssertTrue(state.deletedIDs.isEmpty)
        XCTAssertEqual(sync.displayedDocuments.map(\.deviceID), [stableID])
    }

    func testReenableBeforeIdentityIsReadyPreservesCurrentDocument() async throws {
        let defaults = makeDefaults()
        let cachedID = UUID().uuidString.lowercased()
        let stableID = UUID().uuidString.lowercased()
        defaults.set(cachedID, forKey: deviceIDKey)
        defaults.set(stableID, forKey: pendingDeletionKey)
        defaults.set(true, forKey: enabledKey)
        let identity = BlockingIdentityStore(storedID: stableID)
        defer { identity.release() }
        let history = IdentityPreparationHistoryStore()
        let sync = makeSync(defaults: defaults, identity: identity, history: history)
        try await waitUntil { identity.readStarted }

        sync.enabled = false
        XCTAssertTrue(defaults.bool(forKey: pendingIdentityDeletionKey))
        XCTAssertEqual(defaults.string(forKey: pendingDeletionKey), stableID)
        sync.enabled = true
        XCTAssertFalse(defaults.bool(forKey: pendingIdentityDeletionKey))
        XCTAssertEqual(defaults.string(forKey: pendingDeletionKey), stableID)
        try await assertNoCloudIO(history)

        identity.release()
        try await waitUntil {
            let state = await history.snapshot()
            return sync.isIdentityReady && !state.writtenIDs.isEmpty && !sync.isSyncing
        }

        let state = await history.snapshot()
        XCTAssertTrue(sync.enabled)
        XCTAssertEqual(sync.deviceID, stableID)
        XCTAssertTrue(state.deletedIDs.isEmpty)
        XCTAssertTrue(state.writtenIDs.allSatisfy { $0 == stableID })
        XCTAssertNil(defaults.object(forKey: pendingDeletionKey))
        XCTAssertFalse(defaults.bool(forKey: pendingIdentityDeletionKey))
    }

    func testDisableBeforeIdentityIsReadyPreservesDeletionIntentForRelaunch() async throws {
        let defaults = makeDefaults()
        let cachedID = UUID().uuidString.lowercased()
        let previousID = UUID().uuidString.lowercased()
        let stableID = UUID().uuidString.lowercased()
        defaults.set(cachedID, forKey: deviceIDKey)
        defaults.set(previousID, forKey: pendingDeletionKey)
        defaults.set(true, forKey: enabledKey)
        let identity = BlockingIdentityStore(storedID: stableID)
        defer { identity.release() }
        let history = IdentityPreparationHistoryStore()
        let sync = makeSync(defaults: defaults, identity: identity, history: history)
        try await waitUntil { identity.readStarted }

        sync.enabled = false
        XCTAssertFalse(defaults.bool(forKey: enabledKey))
        XCTAssertTrue(defaults.bool(forKey: pendingIdentityDeletionKey))
        XCTAssertEqual(defaults.string(forKey: pendingDeletionKey), previousID)
        try await assertNoCloudIO(history)

        // 준비 대기 시점의 영속 상태만 복사해 종료·재시작 경계 재현.
        let restoredDefaults = makeDefaults()
        for key in [enabledKey, deviceIDKey, pendingDeletionKey, pendingIdentityDeletionKey] {
            if let value = defaults.object(forKey: key) { restoredDefaults.set(value, forKey: key) }
        }
        identity.release()
        try await waitUntil {
            let state = await history.snapshot()
            return sync.isIdentityReady && state.deletedIDs == [previousID, stableID] && !sync.isSyncing
        }

        let relaunchedIdentity = BlockingIdentityStore(storedID: stableID)
        defer { relaunchedIdentity.release() }
        let relaunchedHistory = IdentityPreparationHistoryStore()
        let relaunched = makeSync(
            defaults: restoredDefaults, identity: relaunchedIdentity, history: relaunchedHistory
        )
        try await waitUntil { relaunchedIdentity.readStarted }
        XCTAssertFalse(relaunched.enabled)
        XCTAssertTrue(restoredDefaults.bool(forKey: pendingIdentityDeletionKey))
        try await assertNoCloudIO(relaunchedHistory)

        relaunchedIdentity.release()
        try await waitUntil {
            let state = await relaunchedHistory.snapshot()
            return relaunched.isIdentityReady && state.deletedIDs == [previousID, stableID] && !relaunched.isSyncing
        }

        let state = await relaunchedHistory.snapshot()
        XCTAssertEqual(relaunched.deviceID, stableID)
        XCTAssertTrue(state.writtenIDs.isEmpty)
        XCTAssertFalse(state.deletedIDs.contains(cachedID))
        XCTAssertNil(restoredDefaults.object(forKey: pendingDeletionKey))
        XCTAssertFalse(restoredDefaults.bool(forKey: pendingIdentityDeletionKey))
    }

    func testDisabledLaunchWithoutDeletionIntentPreparesIdentityWithoutCloudIO() async throws {
        let defaults = makeDefaults()
        let cachedID = UUID().uuidString.lowercased()
        defaults.set(cachedID, forKey: deviceIDKey)
        let identity = BlockingIdentityStore(storedID: nil)
        defer { identity.release() }
        let history = IdentityPreparationHistoryStore()
        let sync = makeSync(defaults: defaults, identity: identity, history: history)
        try await waitUntil { identity.readStarted }
        try await assertNoCloudIO(history)

        identity.release()
        try await waitUntil { sync.isIdentityReady }

        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.deviceID, cachedID)
        XCTAssertEqual(identity.writtenIDs, [cachedID])
        XCTAssertEqual(identity.writeWasOnMainThread, false)
        XCTAssertNil(defaults.object(forKey: pendingDeletionKey))
        XCTAssertFalse(defaults.bool(forKey: pendingIdentityDeletionKey))
        try await assertNoCloudIO(history)
    }

    private func makeSync(
        defaults: UserDefaults, identity: BlockingIdentityStore, history: IdentityPreparationHistoryStore
    ) -> ICloudUsageSyncStore {
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []), providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )
        return ICloudUsageSyncStore(
            dataStore: dataStore, defaults: defaults, fileStore: history, deviceIDStore: identity,
            writeDebounce: .milliseconds(5), observesMetadataChanges: false
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "OpenUsageTests.ICloudIdentityPreparation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func assertNoCloudIO(_ history: IdentityPreparationHistoryStore) async throws {
        try await Task.sleep(for: .milliseconds(40))
        let state = await history.snapshot()
        XCTAssertEqual(state.loadCount, 0)
        XCTAssertTrue(state.writtenIDs.isEmpty)
        XCTAssertTrue(state.deletedIDs.isEmpty)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw IdentityPreparationFixtureError.conditionTimedOut
    }
}

private final class BlockingIdentityStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let readGate = DispatchSemaphore(value: 0)
    private let storedID: String?
    private var didStartRead = false
    private var readOnMain: Bool?
    private var writeOnMain: Bool?
    private var writes: [String] = []

    init(storedID: String?) { self.storedID = storedID }

    var readStarted: Bool { lock.withLock { didStartRead } }
    var readWasOnMainThread: Bool? { lock.withLock { readOnMain } }
    var writeWasOnMainThread: Bool? { lock.withLock { writeOnMain } }
    var writtenIDs: [String] { lock.withLock { writes } }

    func readDeviceID() throws -> String? {
        lock.withLock {
            didStartRead = true
            readOnMain = Thread.isMainThread
        }
        guard readGate.wait(timeout: .now() + 5) == .success else {
            throw IdentityPreparationFixtureError.readTimedOut
        }
        return storedID
    }

    func writeDeviceID(_ deviceID: String) throws {
        lock.withLock {
            writeOnMain = Thread.isMainThread
            writes.append(deviceID)
        }
    }

    func release() { readGate.signal() }
}

private actor IdentityPreparationHistoryStore: UsageHistoryFileStoring {
    struct Snapshot: Sendable {
        var loadCount: Int
        var writtenIDs: [String]
        var deletedIDs: [String]
    }

    private var documents: [UsageHistoryDocument] = []
    private var loadCount = 0
    private var writtenIDs: [String] = []
    private var deletedIDs: [String] = []

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        loadCount += 1
        return UsageHistoryLoadResult(documents: documents)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        writtenIDs.append(document.deviceID)
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func delete(deviceID: String) async throws {
        deletedIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }

    func snapshot() -> Snapshot {
        Snapshot(loadCount: loadCount, writtenIDs: writtenIDs, deletedIDs: deletedIDs)
    }
}

private enum IdentityPreparationFixtureError: Error {
    case readTimedOut
    case conditionTimedOut
}
