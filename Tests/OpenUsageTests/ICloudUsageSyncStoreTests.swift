import XCTest
@testable import OpenUsage

@MainActor
final class ICloudUsageSyncStoreTests: XCTestCase {
    func testEnableWritesLoadsAndDisableDeletesThisMac() async throws {
        let defaults = makeDefaults("enable-disable")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 && sync.displayedDocuments.count == 1 }

        XCTAssertEqual(sync.displayedDocuments.first?.deviceID, sync.deviceID)
        XCTAssertNil(sync.serviceError)

        sync.enabled = false
        try await waitUntil { await fileStore.deletedDeviceIDs.contains(sync.deviceID) }
        XCTAssertTrue(sync.documents.isEmpty)
    }

    func testAdjacentHistoryChangesDebounceToOneWrite() async throws {
        let defaults = makeDefaults("debounce")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(20),
            observesMetadataChanges: false
        )
        sync.enabled = true
        try await waitUntil { await fileStore.writeCount == 1 }

        sync.scheduleWrite()
        sync.scheduleWrite()
        sync.scheduleWrite()
        try await waitUntil { await fileStore.writeCount == 2 }
        try await Task.sleep(for: .milliseconds(40))

        let writeCount = await fileStore.writeCount
        XCTAssertEqual(writeCount, 2)
    }

    func testDisableDeletesWriteThatWasAlreadyInFlight() async throws {
        let defaults = makeDefaults("disable-in-flight-write")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        // enable 쓰기를 붙잡아 disable과 의도적으로 경합 — CI 부하에 좌우되는 sleep 의존 제거
        await fileStore.holdNextWrite()
        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }

        sync.enabled = false
        try await waitUntil {
            await fileStore.deletedDeviceIDs.contains(sync.deviceID)
        }

        await fileStore.releaseWrite()
        try await waitUntil {
            let deletedCount = await fileStore.deletedDeviceIDs.filter { $0 == sync.deviceID }.count
            let writeInFlight = await fileStore.writeInFlight
            return deletedCount >= 2 && !writeInFlight && !sync.isSyncing
        }

        let documents = await fileStore.documents
        XCTAssertFalse(documents.contains { $0.deviceID == sync.deviceID })
    }

    func testStaleEnableFailureDoesNotOverrideReenabledGeneration() async throws {
        let defaults = makeDefaults("stale-enable-generation")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        await fileStore.holdNextWrite()
        await fileStore.failNextWrite()
        sync.enabled = true
        try await waitUntil { await fileStore.writeInFlight }

        sync.enabled = false
        sync.enabled = true
        try await waitUntil {
            let writeCount = await fileStore.writeCount
            let documents = await fileStore.documents
            return writeCount >= 2 && documents.contains { $0.deviceID == sync.deviceID }
        }

        await fileStore.releaseWrite()
        try await waitUntil { !sync.isSyncing }

        XCTAssertTrue(sync.enabled)
        XCTAssertNil(sync.serviceError, "the superseded enable task must not surface its write failure")
    }

    func testHistoryFileStoreRejectsInvalidDeviceIDBeforeICloudAccess() async {
        let fileStore = ICloudUsageHistoryFileStore()

        do {
            try await fileStore.delete(deviceID: "../outside")
            XCTFail("expected an invalid device identifier error")
        } catch let error as ICloudUsageSyncError {
            switch error {
            case .invalidDeviceID:
                break
            case .unavailable:
                XCTFail("iCloud lookup happened before device identifier validation")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testUnavailableStoreSurfacesFriendlyError() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let defaults = makeDefaults("unavailable")
        let fileStore = RecordingHistoryFileStore(unavailable: true)
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { sync.serviceError != nil && !sync.isSyncing }

        XCTAssertEqual(sync.serviceError, ICloudUsageSyncError.unavailable.localizedDescription)
        XCTAssertTrue(diagnostics.events.contains { $0.operation == .iCloudWrite && $0.result == .failure })
        XCTAssertFalse(sync.isSyncing)
    }

    func testMalformedPeerMessageIsVisibleAndValidDocumentsStillLoad() async throws {
        let defaults = makeDefaults("malformed")
        let peer = UsageHistoryDocument(
            deviceID: "peer",
            deviceName: "Peer Mac",
            updatedAt: .now,
            providers: [:]
        )
        let fileStore = RecordingHistoryFileStore(
            seedDocuments: [peer],
            invalidFileMessages: ["broken.json: invalid value"]
        )
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil { sync.invalidFileMessages.count == 1 }

        XCTAssertTrue(sync.displayedDocuments.contains { $0.deviceID == "peer" })
        XCTAssertNotNil(sync.serviceError)
    }

    func testBackgroundReloadShowsSyncActivity() async throws {
        let defaults = makeDefaults("background-sync-activity")
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults),
            defaults: defaults,
            fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(),
            writeDebounce: .milliseconds(10),
            observesMetadataChanges: false
        )

        sync.enabled = true
        try await waitUntil {
            await fileStore.writeCount == 1 && !sync.isSyncing
        }

        // 쓰기 이후 reload만 gate — isSyncing 관찰 가능하도록 유지
        await fileStore.holdNextLoad()
        sync.scheduleWrite()
        try await waitUntil {
            let writeCount = await fileStore.writeCount
            let loadInFlight = await fileStore.loadInFlight
            return writeCount == 2 && loadInFlight && sync.isSyncing
        }

        await fileStore.releaseLoad()
        try await waitUntil { !sync.isSyncing }
    }

    func testDeviceIdentitySurvivesPreferencesResetThroughKeychainStore() {
        let expectedID = UUID().uuidString.lowercased()
        let firstDefaults = makeDefaults("identity-first")
        firstDefaults.set(expectedID, forKey: "openusage.icloudSync.deviceID.v1")
        let deviceIDStore = MemoryDeviceIDStore()

        let first = ICloudUsageSyncStore(
            dataStore: makeDataStore(firstDefaults),
            defaults: firstDefaults,
            fileStore: RecordingHistoryFileStore(),
            deviceIDStore: deviceIDStore,
            observesMetadataChanges: false
        )
        let resetDefaults = makeDefaults("identity-after-reset")
        let afterReset = ICloudUsageSyncStore(
            dataStore: makeDataStore(resetDefaults),
            defaults: resetDefaults,
            fileStore: RecordingHistoryFileStore(),
            deviceIDStore: deviceIDStore,
            observesMetadataChanges: false
        )

        XCTAssertEqual(first.deviceID, expectedID)
        XCTAssertEqual(afterReset.deviceID, expectedID)
        XCTAssertEqual(resetDefaults.string(forKey: "openusage.icloudSync.deviceID.v1"), expectedID)
    }

    func testKeychainIdentityIsScopedToDevelopmentAndProductionBundles() throws {
        let keychain = ServiceKeychain()
        let development = KeychainICloudDeviceIDStore(
            keychain: keychain,
            bundleIdentifier: "com.kimchanhyung98.openusage.dev"
        )
        let production = KeychainICloudDeviceIDStore(
            keychain: keychain,
            bundleIdentifier: "com.kimchanhyung98.openusage"
        )

        try development.writeDeviceID("development-id")
        try production.writeDeviceID("production-id")

        XCTAssertEqual(try development.readDeviceID(), "development-id")
        XCTAssertEqual(try production.readDeviceID(), "production-id")
    }

    func testStartupIdentityFailureIsRecordedOnceOnlyWhenTelemetryWasEnabled() async throws {
        for enabled in [false, true] {
            for failsOnRead in [false, true] {
                let defaults = makeDefaults("startup-diagnostics-\(enabled)-\(failsOnRead)")
                let savedID = UUID().uuidString.lowercased()
                defaults.set(savedID, forKey: "openusage.icloudSync.deviceID.v1")
                let telemetryStore = TelemetryStore(defaults: defaults)
                telemetryStore.enabled = enabled
                let sink = ICloudTelemetrySink()
                let recorder = TelemetryRecorder(sink: sink, store: telemetryStore, snapshot: {
                    TelemetryConfigSnapshot(enabledProviders: [], enabledMetricIDs: [], pinnedMetricIDs: [],
                                            expandedMetricIDs: [], menuBarStyle: "text")
                })
                recorder.startDiagnostics()
                defer { recorder.stopDiagnostics() }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                let originalSink = AppLog.sink
                let log = LogFile(directory: directory, fileName: "startup.log")
                AppLog.sink = log
                defer { AppLog.sink = originalSink; try? FileManager.default.removeItem(at: directory) }

                let sync = ICloudUsageSyncStore(
                    dataStore: makeDataStore(defaults), defaults: defaults, fileStore: RecordingHistoryFileStore(),
                    deviceIDStore: FailingDeviceIDStore(failsOnRead: failsOnRead), observesMetadataChanges: false
                )
                if enabled { try await waitUntil { sink.events.count == 1 } }

                XCTAssertEqual(sync.deviceID, savedID)
                XCTAssertNotNil(sync.serviceError)
                let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
                XCTAssertEqual(lines.filter { $0.contains("[ERROR]") }.count, 1)
                XCTAssertTrue(lines.contains { $0.contains("error_domain=NSOSStatusErrorDomain error_code=-25293") })
                XCTAssertEqual(sink.events.count, enabled ? 1 : 0)
                let counters = Array(telemetryStore.featureCounters().values)
                XCTAssertEqual(counters.count, enabled ? 1 : 0)
                if enabled {
                    XCTAssertEqual(counters.first?.count, 1)
                    XCTAssertEqual(counters.first?.event.operation, .iCloudIdentity)
                    XCTAssertEqual(counters.first?.event.result, .failure)
                    XCTAssertNil(counters.first?.event.provider)
                    XCTAssertEqual(sink.events.first?.0, "feature_operation_result")
                    let properties = try XCTUnwrap(sink.events.first?.1)
                    XCTAssertEqual(properties["count"] as? Int, 1)
                    XCTAssertEqual(Set(properties.keys), ["schema_version", "day", "app_version", "build_channel",
                                                        "feature", "operation", "result", "error_category", "count"])
                    let payload = String(describing: properties)
                    XCTAssertFalse(payload.contains(savedID))
                    XCTAssertFalse(payload.contains("private-identity-detail"))
                }
            }
        }
    }

    func testInvalidDeletionRequestWritesOneLocalErrorAndOneDiagnostic() async throws {
        let defaults = makeDefaults("invalid-deletion-diagnostic")
        defaults.set("../private-device-id", forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1")
        let diagnostics = DiagnosticEventRecorder()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let originalSink = AppLog.sink
        let log = LogFile(directory: directory, fileName: "deletion.log")
        AppLog.sink = log
        defer { AppLog.sink = originalSink; try? FileManager.default.removeItem(at: directory) }
        let fileStore = RecordingHistoryFileStore()
        let sync = ICloudUsageSyncStore(
            dataStore: makeDataStore(defaults), defaults: defaults, fileStore: fileStore,
            deviceIDStore: MemoryDeviceIDStore(), observesMetadataChanges: false
        )
        try await waitUntil { sync.deletionError != nil }

        let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.contains("[ERROR]") }.count, 1)
        XCTAssertTrue(lines.contains { $0.contains("invalid device identifier") })
        XCTAssertFalse(lines.contains { $0.contains("private-device-id") })
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.iCloudDelete, result: .failure, category: .decoding)])
        let deleted = await fileStore.deletedDeviceIDs
        XCTAssertTrue(deleted.isEmpty)
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

private final class MemoryDeviceIDStore: ICloudDeviceIDStoring, @unchecked Sendable {
    private var deviceID: String?

    func readDeviceID() throws -> String? {
        deviceID
    }

    func writeDeviceID(_ deviceID: String) throws {
        self.deviceID = deviceID
    }
}

private actor RecordingHistoryFileStore: UsageHistoryFileStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var invalidFileMessages: [String]
    private(set) var writeCount = 0
    private(set) var deletedDeviceIDs: [String] = []
    private let unavailable: Bool
    private(set) var loadInFlight = false
    private(set) var writeInFlight = false
    private var shouldHoldNextLoad = false
    private var shouldHoldNextWrite = false
    private var shouldFailNextWrite = false
    private var loadGate: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?

    init(
        unavailable: Bool = false,
        seedDocuments: [UsageHistoryDocument] = [],
        invalidFileMessages: [String] = []
    ) {
        self.unavailable = unavailable
        self.documents = seedDocuments
        self.invalidFileMessages = invalidFileMessages
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        loadInFlight = true
        defer { loadInFlight = false }
        if shouldHoldNextLoad {
            shouldHoldNextLoad = false
            await withCheckedContinuation { continuation in
                loadGate = continuation
            }
        }
        return UsageHistoryLoadResult(documents: documents, invalidFileMessages: invalidFileMessages)
    }

    func write(_ document: UsageHistoryDocument) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        let shouldFail = shouldFailNextWrite
        shouldFailNextWrite = false
        writeCount += 1
        writeInFlight = true
        defer { writeInFlight = false }
        if shouldHoldNextWrite {
            shouldHoldNextWrite = false
            await withCheckedContinuation { continuation in
                writeGate = continuation
            }
        }
        if shouldFail { throw ICloudUsageSyncError.unavailable }
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
    }

    func delete(deviceID: String) async throws {
        if unavailable { throw ICloudUsageSyncError.unavailable }
        deletedDeviceIDs.append(deviceID)
        documents.removeAll { $0.deviceID == deviceID }
    }

    func holdNextLoad() {
        shouldHoldNextLoad = true
    }

    func holdNextWrite() {
        shouldHoldNextWrite = true
    }

    func failNextWrite() {
        shouldFailNextWrite = true
    }

    func releaseLoad() {
        loadGate?.resume()
        loadGate = nil
    }

    func releaseWrite() {
        writeGate?.resume()
        writeGate = nil
    }
}

private struct FailingDeviceIDStore: ICloudDeviceIDStoring {
    let failsOnRead: Bool
    private var failure: NSError {
        NSError(domain: NSOSStatusErrorDomain, code: -25293,
                userInfo: [NSLocalizedDescriptionKey: "private-identity-detail"])
    }
    func readDeviceID() throws -> String? { if failsOnRead { throw failure }; return nil }
    func writeDeviceID(_ deviceID: String) throws { throw failure }
}

@MainActor
private final class ICloudTelemetrySink: TelemetrySink {
    var events: [(String, [String: Any])] = []
    func capture(_ event: String, _ properties: [String: Any]) { events.append((event, properties)) }
    func setEnabled(_ enabled: Bool) {}
    func flush() {}
}
