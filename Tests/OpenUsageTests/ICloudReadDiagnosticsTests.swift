import XCTest
@testable import OpenUsage

@MainActor
final class ICloudReadDiagnosticsTests: XCTestCase {
    func testLoadResultRetainsFileMessagesAndDistinctErrorCategories() {
        let peer = UsageHistoryDocument(deviceID: "peer", deviceName: "Peer Mac", updatedAt: .now, providers: [:])
        let result = Self.partialResult(documents: [peer])

        XCTAssertEqual(result.documents, [peer])
        XCTAssertEqual(result.invalidFileMessages.count, 5)
        XCTAssertEqual(result.failureCategories, [.permission, .storage, .decoding, .other])
        XCTAssertTrue(result.invalidFileMessages.contains { $0.contains("PRIVATE_PERMISSION.json") })
        XCTAssertTrue(result.invalidFileMessages.contains { $0.contains("PRIVATE_SCHEMA.json") })
    }

    func testPartialReadRecordsEachCategoryOnceThenSuccessfulRead() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let fileStore = HistoryStore(result: Self.partialResult())
        let sync = makeSync(fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { await fileStore.completedLoads == 2 && !sync.isSyncing }

        let reads = diagnostics.events.filter { $0.operation == .iCloudRead }
        XCTAssertEqual(reads, [
            DiagnosticEvent(.iCloudRead, result: .degraded, category: .decoding),
            DiagnosticEvent(.iCloudRead, result: .degraded, category: .other),
            DiagnosticEvent(.iCloudRead, result: .degraded, category: .permission),
            DiagnosticEvent(.iCloudRead, result: .degraded, category: .storage),
            DiagnosticEvent(.iCloudRead, result: .success)
        ])
        XCTAssertTrue(sync.invalidFileMessages.isEmpty)
        XCTAssertNil(sync.serviceError)
        let encoded = String(decoding: try JSONEncoder().encode(reads), as: UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE_"))
    }

    func testReadCompletedAfterDisablingSyncDoesNotReportStaleFailures() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let fileStore = HistoryStore(result: Self.partialResult(), holdFirstLoad: true)
        let sync = makeSync(fileStore: fileStore)

        sync.enabled = true
        try await waitUntil { await fileStore.loadInFlight }
        sync.enabled = false
        await fileStore.releaseLoad()
        try await waitUntil { await fileStore.completedLoads == 1 && !sync.isSyncing }

        XCTAssertTrue(diagnostics.events.filter { $0.operation == .iCloudRead }.isEmpty)
        XCTAssertTrue(sync.invalidFileMessages.isEmpty)
        XCTAssertNil(sync.serviceError)
    }

    private static func partialResult(documents: [UsageHistoryDocument] = []) -> UsageHistoryLoadResult {
        var result = UsageHistoryLoadResult(documents: documents)
        result.appendFailure(CocoaError(.fileReadNoPermission), fileName: "PRIVATE_PERMISSION.json")
        result.appendFailure(CocoaError(.fileReadNoPermission), fileName: "PRIVATE_SECOND_PERMISSION.json")
        result.appendFailure(CocoaError(.fileReadUnknown), fileName: "PRIVATE_STORAGE.json")
        result.appendFailure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "PRIVATE_JSON")),
                             fileName: "PRIVATE_DECODING.json")
        result.appendFailure(UsageHistoryDocumentError.invalidDay("PRIVATE_DAY"), fileName: "PRIVATE_SCHEMA.json")
        return result
    }

    private func makeSync(fileStore: HistoryStore) -> ICloudUsageSyncStore {
        let suite = "OpenUsageTests.ICloudReadDiagnostics.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []),
            providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
        return ICloudUsageSyncStore(
            dataStore: dataStore,
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: DeviceIDStore(),
            observesMetadataChanges: false
        )
    }

    private func waitUntil(condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }

    private struct DeviceIDStore: ICloudDeviceIDStoring {
        func readDeviceID() throws -> String? { "a1234567-1234-1234-1234-123456789abc" }
        func writeDeviceID(_ deviceID: String) throws {}
    }

    private actor HistoryStore: UsageHistoryFileStoring {
        private var result: UsageHistoryLoadResult
        private var holdFirstLoad: Bool
        private var loadGate: CheckedContinuation<Void, Never>?
        private(set) var loadInFlight = false
        private(set) var completedLoads = 0

        init(result: UsageHistoryLoadResult, holdFirstLoad: Bool = false) {
            self.result = result
            self.holdFirstLoad = holdFirstLoad
        }

        func loadDocuments() async throws -> UsageHistoryLoadResult {
            let current = result
            result = UsageHistoryLoadResult(documents: [])
            loadInFlight = true
            if holdFirstLoad {
                holdFirstLoad = false
                await withCheckedContinuation { loadGate = $0 }
            }
            loadInFlight = false
            completedLoads += 1
            return current
        }

        func releaseLoad() {
            loadGate?.resume()
            loadGate = nil
        }

        func write(_ document: UsageHistoryDocument) async throws {}
        func delete(deviceID: String) async throws {}
    }
}
