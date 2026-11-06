import XCTest
@testable import OpenUsage

@MainActor
final class OpenCodeSharedUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00Z")!

    func testReportedSharedCostReachesSpendWithoutChangingGoMeters() async throws {
        let provider = makeProvider(records: [record(cost: 2)], native: true)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 3)
        guard case let .progress(_, used, _, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected native Go meter")
        }
        XCTAssertEqual(used, 1)
    }

    func testEstimatedSharedCostKeepsTokensAndMakesTotalCostIncomplete() async {
        for origin in [UsageRecord.CostOrigin.estimated, .creditEquivalent] {
            let provider = makeProvider(records: [record(cost: 9, origin: origin)], native: true)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 300)
            XCTAssertNil(snapshot.usageHistory?.series.daily.first?.costUSD)
            XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        }
    }

    func testReportedZeroWithOnlySharedUsageDoesNotCreateGoMeters() async throws {
        let provider = makeProvider(records: [record(cost: 0)], native: false)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        guard case let .values(_, values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected reported zero spend")
        }
        XCTAssertFalse(values.contains(where: \.estimated))
    }

    func testNativeReadFailurePreservesSharedHistoryWithoutGoMeters() async {
        for hasGoKey in [true, false] {
            let provider = makeProvider(records: [record(cost: 2)], native: true,
                                        nativeFailure: true, hasGoKey: hasGoKey)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 200)
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 2)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertNil(snapshot.plan)
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertFalse(snapshot.lines.contains(where: \.isError))
            XCTAssertTrue(snapshot.warning?.contains(OpenCodeUsageError.databaseUnreadable.localizedDescription) == true)
        }
    }

    func testNativeReadFailureWithoutSharedHistoryDoesNotShowZeroUsage() async {
        for sharedFailure in [true, false] {
            let provider = makeProvider(records: [], native: true, nativeFailure: true,
                                        hasGoKey: true, sharedFailure: sharedFailure)
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.usageHistory)
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertTrue(snapshot.lines.contains(where: \.isError))
        }
    }

    func testCancelledRefreshDoesNotPublishSharedHistory() async {
        let started = expectation(description: "shared collection started")
        let collector = SuspendedOpenCodeSharedRecords(records: [record(cost: 2)]) { started.fulfill() }
        let provider = makeProvider(records: [], native: true, sharedUsage: .init(collectors: [collector]))
        let refresh = Task { await provider.refresh() }
        await fulfillment(of: [started], timeout: 2)
        refresh.cancel()
        await collector.release()
        let snapshot = await refresh.value
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(snapshot.lines.contains(where: \.isError))
    }

    func testSharedLocalDetectionRequiresUsableOpenCodeAttribution() async {
        for source in ["pi", "omp"] {
            for providerID in ["opencode", "opencode-go", "anthropic"] {
                var usage = record(cost: 0)
                usage.sourceID = source
                usage.providerID = providerID
                usage.recordedCostUSD = nil
                let provider = makeProvider(records: [usage], native: false)

                let detected = await provider.hasLocalCredentials()

                XCTAssertEqual(detected, providerID != "anthropic")
            }
        }
    }

    func testEmptyRejectedAndExpiredSharedRecordsDoNotAutoEnableOpenCode() async {
        var invalid = record(cost: 2)
        invalid.issues = [.invalidMetadata]
        var expired = record(cost: 2)
        expired.timestamp = now.addingTimeInterval(-40 * 86_400)
        for records in [[], [invalid], [expired]] {
            let provider = makeProvider(records: records, native: false)
            let detected = await provider.hasLocalCredentials()
            XCTAssertFalse(detected)
        }
        let failed = makeProvider(records: [], native: false, sharedFailure: true)
        let detected = await failed.hasLocalCredentials()
        XCTAssertFalse(detected)
    }

    func testCompletedEmptySharedHistoryClearsPreviouslySavedSharedOnlyUsage() async throws {
        let collector = MutableOpenCodeSharedRecords(records: [record(cost: 2)])
        let provider = makeProvider(records: [], native: false, sharedUsage: .init(collectors: [collector]))
        let suite = "OpenCodeSharedUsageTests.empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = now
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache,
                                    defaults: defaults, now: { now })
        let initiallyDetected = await provider.hasLocalCredentials()
        XCTAssertTrue(initiallyDetected)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 200)

        await collector.removeRecords()
        let detectedAfterRemoval = await provider.hasLocalCredentials()
        XCTAssertFalse(detectedAfterRemoval)
        await store.refreshAll(force: true)

        XCTAssertNil(store.providerErrors["opencode"])
        XCTAssertEqual(store.localSnapshots["opencode"]?.usageHistory?.series.daily, [])
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["opencode"])["opencode"]?.usageHistory?.series.daily, [])
        XCTAssertNil(store.localSnapshots["opencode"]?.line(label: "Session"))
    }

    private func record(cost: Double, origin: UsageRecord.CostOrigin = .reported) -> UsageRecord {
        UsageRecord(
            sourceID: "pi", formatID: "pi-session", sessionID: "shared-session", id: "shared-request",
            kind: "message", timestamp: now.addingTimeInterval(-1800), providerID: "opencode-go",
            model: "glm-5.2", totalTokens: 200, recordedCostUSD: cost, costOrigin: origin
        )
    }

    private func makeProvider(
        records: [UsageRecord], native: Bool, nativeFailure: Bool = false,
        hasGoKey: Bool = false, sharedFailure: Bool = false,
        sharedUsage: UsageCollectionCoordinator? = nil
    ) -> OpenCodeProvider {
        let now = self.now
        let timestamp = Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let payload = "[[\(timestamp),1,100,\"glm-5.2\",\"opencode-go\"]]"
        return OpenCodeProvider(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(hasGoKey ? ["/fixture/auth.json": #"{"opencode-go":{"type":"api","key":"fixture"}}"#] : [:]),
                environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/fixture"]),
                homeDirectory: { URL(fileURLWithPath: "/fixture-home") }
            ),
            usageScanner: OpenCodeUsageScanner(
                sqlite: SharedOpenCodeSQLite(payload: payload, shouldFail: nativeFailure),
                databasePaths: { native ? ["/fixture/opencode.db"] : [] }
            ),
            sharedUsage: sharedUsage ?? .init(collectors: [SharedOpenCodeRecords(records: records, shouldFail: sharedFailure)]),
            now: { now }
        )
    }
}

private struct SharedOpenCodeRecords: UsageCollecting {
    let records: [UsageRecord]
    var shouldFail = false
    func collect(since: Date) async -> UsageCollection? {
        UsageCollection(records: records, sources: [
            .init(sourceID: "pi", completedStores: shouldFail ? 0 : 1, failedStores: shouldFail ? 1 : 0)
        ])
    }
}

private struct SharedOpenCodeSQLite: SQLiteAccessing {
    let payload: String
    var shouldFail = false
    func queryValue(path: String, sql: String) throws -> String? {
        if shouldFail { throw OpenCodeUsageError.databaseUnreadable }
        if sql.contains("json_group_array") { return payload }
        return nil
    }
    func execute(path: String, sql: String) throws {}
}

private actor MutableOpenCodeSharedRecords: UsageCollecting {
    private var records: [UsageRecord]

    init(records: [UsageRecord]) { self.records = records }

    func removeRecords() { records.removeAll() }

    func collect(since: Date) async -> UsageCollection? {
        UsageCollection(records: records, sources: [.init(sourceID: "pi", completedStores: 1)])
    }
}

private actor SuspendedOpenCodeSharedRecords: UsageCollecting {
    let records: [UsageRecord]
    let onStart: @Sendable () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    init(records: [UsageRecord], onStart: @escaping @Sendable () -> Void) {
        self.records = records
        self.onStart = onStart
    }

    func collect(since: Date) async -> UsageCollection? {
        onStart()
        if !released { await withCheckedContinuation { continuation = $0 } }
        return UsageCollection(records: records, sources: [.init(sourceID: "pi", completedStores: 1)])
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
