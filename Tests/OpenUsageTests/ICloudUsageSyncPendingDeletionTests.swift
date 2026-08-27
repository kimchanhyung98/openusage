import XCTest
@testable import OpenUsage

@MainActor
final class ICloudUsageSyncPendingDeletionTests: XCTestCase {
    func testFailedDisableDeletionRetriesAfterRelaunchWhileSyncRemainsOff() async throws {
        let defaults = makeDefaults("pending-deletion-retry")
        let fileStore = PendingDeletionHistoryFileStore()
        let dataStore = makeDataStore(defaults)
        let sync = makeSync(dataStore: dataStore, defaults: defaults, fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 }

        await fileStore.failNextDeletes(1)
        sync.enabled = false
        try await waitUntil { await fileStore.deleteAttempts.count == 1 }
        try await waitUntil { sync.serviceError != nil }
        XCTAssertEqual(
            sync.serviceError,
            "OpenUsage couldn’t remove this Mac’s synced usage history from iCloud. It will try again automatically."
        )
        XCTAssertFalse(defaults.bool(forKey: "openusage.icloudSync.enabled.v1"))
        XCTAssertEqual(
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1"),
            sync.deviceID,
            "a failed deletion must leave a durable trace"
        )

        let relaunched = makeSync(dataStore: dataStore, defaults: defaults, fileStore: fileStore)
        XCTAssertFalse(relaunched.enabled)
        try await waitUntil { await fileStore.deletedDeviceIDs.contains(relaunched.deviceID) }
        try await waitUntil {
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1") == nil
        }
        XCTAssertNil(relaunched.serviceError)
    }

    func testPendingDeletionSurvivesRepeatedFailuresUntilDeleteSucceeds() async throws {
        let defaults = makeDefaults("pending-deletion-repeat")
        let fileStore = PendingDeletionHistoryFileStore()
        let dataStore = makeDataStore(defaults)
        let sync = makeSync(dataStore: dataStore, defaults: defaults, fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 }

        await fileStore.failNextDeletes(2)
        sync.enabled = false
        try await waitUntil { await fileStore.deleteAttempts.count == 1 }

        let secondLaunch = makeSync(dataStore: dataStore, defaults: defaults, fileStore: fileStore)
        try await waitUntil { await fileStore.deleteAttempts.count == 2 }
        XCTAssertEqual(
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1"),
            secondLaunch.deviceID,
            "the tombstone stays until a deletion actually succeeds"
        )

        let thirdLaunch = makeSync(dataStore: dataStore, defaults: defaults, fileStore: fileStore)
        try await waitUntil { await fileStore.deletedDeviceIDs.contains(thirdLaunch.deviceID) }
        try await waitUntil {
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1") == nil
        }
    }

    func testReenablingSyncClearsPendingDeletionAndKeepsDocument() async throws {
        let defaults = makeDefaults("pending-deletion-reenable")
        let fileStore = PendingDeletionHistoryFileStore()
        let dataStore = makeDataStore(defaults)
        let sync = makeSync(dataStore: dataStore, defaults: defaults, fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 }

        await fileStore.failNextDeletes(1)
        sync.enabled = false
        try await waitUntil { await fileStore.deleteAttempts.count == 1 }

        sync.enabled = true
        try await waitUntil {
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1") == nil
        }
        try await waitUntil { await fileStore.writeCount >= 2 }
        let deleted = await fileStore.deletedDeviceIDs
        XCTAssertFalse(
            deleted.contains(sync.deviceID),
            "turning sync back on must not delete the document it just rewrote"
        )
    }

    func testEnabledLaunchRetriesAndHidesAPendingPreviousDeviceDocument() async throws {
        let defaults = makeDefaults("pending-deletion-previous-device")
        let previousDeviceID = UUID().uuidString.lowercased()
        defaults.set(true, forKey: "openusage.icloudSync.enabled.v1")
        defaults.set(previousDeviceID, forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1")
        let previousDocument = UsageHistoryDocument(
            deviceID: previousDeviceID,
            deviceName: "Previous Mac",
            updatedAt: .now,
            providers: [:]
        )
        let fileStore = PendingDeletionHistoryFileStore(seedDocuments: [previousDocument])
        await fileStore.failNextDeletes(1)

        let sync = makeSync(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore
        )

        try await waitUntil {
            let attemptedPreviousDelete = await fileStore.deleteAttempts.contains(previousDeviceID)
            let writeCount = await fileStore.writeCount
            return attemptedPreviousDelete && writeCount == 1 && !sync.isSyncing
        }
        XCTAssertFalse(sync.displayedDocuments.contains { $0.deviceID == previousDeviceID })
        XCTAssertEqual(
            sync.serviceError,
            "OpenUsage couldn’t remove this Mac’s synced usage history from iCloud. "
                + "It will try again automatically."
        )
        XCTAssertEqual(
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1"),
            previousDeviceID
        )
    }

    func testEnabledSyncPrioritizesOperationFailureOverRetryableDeletionFailure() async throws {
        let defaults = makeDefaults("pending-deletion-error-priority")
        defaults.set(true, forKey: "openusage.icloudSync.enabled.v1")
        let previousDeviceID = UUID().uuidString.lowercased()
        defaults.set(previousDeviceID, forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1")
        let fileStore = PendingDeletionHistoryFileStore()
        await fileStore.failNextDeletes(1)
        await fileStore.failNextWrites(1)

        let sync = makeSync(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore
        )

        try await waitUntil {
            let deleteAttempts = await fileStore.deleteAttempts.count
            let writeCount = await fileStore.writeCount
            return deleteAttempts == 1 && writeCount == 1 && !sync.isSyncing
        }
        XCTAssertNotNil(sync.deletionError)
        XCTAssertEqual(sync.serviceError, ICloudUsageSyncError.unavailable.localizedDescription)
    }

    func testDisabledLaunchDeletesPreviousThenCurrentDeviceWithOnePendingSlot() async throws {
        let suite = "OpenUsageTests.ICloudSync.pending-deletion-handoff.\(UUID().uuidString)"
        let defaults = RecordingPendingDeletionDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let previousDeviceID = UUID().uuidString.lowercased()
        let currentDeviceID = UUID().uuidString.lowercased()
        defaults.set(previousDeviceID, forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1")
        defaults.pendingOperations = []
        let fileStore = PendingDeletionHistoryFileStore()

        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: PendingDeletionDeviceIDStore(currentDeviceID),
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )

        XCTAssertFalse(sync.enabled)
        try await waitUntil {
            let attempts = await fileStore.deleteAttempts
            return attempts == [previousDeviceID, currentDeviceID]
        }
        XCTAssertNil(defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1"))
        XCTAssertEqual(
            defaults.pendingOperations,
            ["set:\(currentDeviceID)", "remove"],
            "the durable slot must change directly from the previous ID to the current ID"
        )
        defaults.removePersistentDomain(forName: suite)
    }

    func testInvalidPersistedDeletionDeviceIDNeverReachesTheFileStore() async throws {
        let defaults = makeDefaults("pending-deletion-invalid-id")
        defaults.set("../outside", forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1")
        let fileStore = PendingDeletionHistoryFileStore()

        let sync = makeSync(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore
        )

        try await waitUntil { sync.deletionError != nil }
        let deleteAttempts = await fileStore.deleteAttempts
        XCTAssertEqual(deleteAttempts, [])
        XCTAssertEqual(
            defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1"),
            "../outside"
        )
    }

    func testNonStringPersistedDeletionDeviceIDNeverReachesTheFileStore() async throws {
        let defaults = makeDefaults("pending-deletion-invalid-type")
        defaults.set(["invalid"], forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1")
        let fileStore = PendingDeletionHistoryFileStore()

        let sync = makeSync(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore
        )

        try await waitUntil { sync.deletionError != nil }
        let deleteAttempts = await fileStore.deleteAttempts
        XCTAssertEqual(deleteAttempts, [])
    }

    private func makeSync(
        dataStore: WidgetDataStore,
        defaults: UserDefaults,
        fileStore: PendingDeletionHistoryFileStore
    ) -> ICloudUsageSyncStore {
        ICloudUsageSyncStore(
            dataStore: dataStore,
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: PendingDeletionDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )
    }

    private func makeDataStore(_ defaults: UserDefaults) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "OpenUsageTests.ICloudSync.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private final class PendingDeletionDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private var deviceID: String?

    init(_ deviceID: String? = nil) {
        self.deviceID = deviceID
    }

    func readDeviceID() throws -> String? {
        deviceID
    }

    func writeDeviceID(_ deviceID: String) throws {
        self.deviceID = deviceID
    }
}

private final class RecordingPendingDeletionDefaults: UserDefaults {
    private static let pendingKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"
    var pendingOperations: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == Self.pendingKey, let value = value as? String {
            pendingOperations.append("set:\(value)")
        }
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        if defaultName == Self.pendingKey {
            pendingOperations.append("remove")
        }
        super.removeObject(forKey: defaultName)
    }
}

private actor PendingDeletionHistoryFileStore: UsageHistoryFileStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var writeCount = 0
    private(set) var deletedDeviceIDs: [String] = []
    private(set) var deleteAttempts: [String] = []
    private var deleteFailuresRemaining = 0
    private var writeFailuresRemaining = 0

    init(seedDocuments: [UsageHistoryDocument] = []) {
        self.documents = seedDocuments
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        UsageHistoryLoadResult(documents: documents, invalidFileMessages: [])
    }

    func write(_ document: UsageHistoryDocument) async throws {
        writeCount += 1
        if writeFailuresRemaining > 0 {
            writeFailuresRemaining -= 1
            throw ICloudUsageSyncError.unavailable
        }
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func failNextDeletes(_ count: Int) {
        deleteFailuresRemaining += count
    }

    func failNextWrites(_ count: Int) {
        writeFailuresRemaining += count
    }

    func delete(deviceID: String) async throws {
        deleteAttempts.append(deviceID)
        if deleteFailuresRemaining > 0 {
            deleteFailuresRemaining -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        deletedDeviceIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }
}
