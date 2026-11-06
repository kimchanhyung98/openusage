import XCTest
@testable import OpenUsage

@MainActor
final class CopilotSharedUsageTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!

    func testNativeReadFailureStillCollectsSharedCopilotHistory() async throws {
        for quotaStatus in [200, 401] {
            let collector = CopilotSharedUsageCollector(collection: sharedCollection())
            let provider = try makeProvider(sqlite: .init(payload: nil), collector: collector, quotaStatus: quotaStatus)

            let snapshot = await provider.refresh()

            let calls = await collector.calls
            XCTAssertEqual(calls, 1)
            let history = try XCTUnwrap(snapshot.usageHistory)
            XCTAssertEqual(history.series.daily.first?.totalTokens, 120)
            XCTAssertEqual(try XCTUnwrap(history.series.daily.first?.costUSD), 0.02, accuracy: 1e-12)
            XCTAssertEqual(snapshot.warning, CopilotHistoryError.databaseUnreadable.localizedDescription)
            XCTAssertEqual(snapshot.isDegraded, true)
            if quotaStatus == 200 {
                XCTAssertNil(snapshot.errorCategory)
                XCTAssertNotNil(snapshot.line(label: "Credits"))
            } else {
                XCTAssertNotNil(snapshot.errorCategory)
            }
        }
    }

    func testBothHistorySourcesFailWithoutPublishingEmptyHistory() async throws {
        let collector = CopilotSharedUsageCollector(collection: UsageCollection(
            records: [],
            sources: [UsageSourceState(sourceID: "pi", failedStores: 1)]
        ))
        let provider = try makeProvider(sqlite: .init(payload: nil), collector: collector)

        let snapshot = await provider.refresh()

        let calls = await collector.calls
        XCTAssertEqual(calls, 1)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertTrue(snapshot.warning?.contains(CopilotHistoryError.databaseUnreadable.localizedDescription) == true)
        XCTAssertTrue(snapshot.warning?.contains("Some local usage files could not be read.") == true)
        XCTAssertNotNil(snapshot.line(label: "Credits"))
    }

    func testMissingNativeCostRemainsUnknownWhenSharedReportedCostExists() async throws {
        let rows: [[Any]] = [[OpenUsageISO8601.string(from: now), "fixture-native", 100, 20, NSNull()]]
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self)
        let collector = CopilotSharedUsageCollector(collection: sharedCollection())
        let provider = try makeProvider(sqlite: .init(payload: payload), collector: collector)

        let snapshot = await provider.refresh()

        let history = try XCTUnwrap(snapshot.usageHistory)
        XCTAssertEqual(history.series.daily.first?.totalTokens, 240)
        XCTAssertNil(history.series.daily.first?.costUSD)
        let models = history.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(models.first { $0.model == "fixture-shared" }?.costUSD, 0.02)
        XCTAssertNil(models.first { $0.model == "fixture-native" }?.costUSD)
        let warning = "Some local usage has unsupported pricing details. Cost totals may be unavailable."
        XCTAssertEqual(snapshot.warning, warning)
        XCTAssertEqual(snapshot.warningPresentation, [LocalizedMessage(warning)])
        guard case .values(_, let values, _, _, _, _) = try XCTUnwrap(snapshot.line(label: "Today")) else {
            return XCTFail("Expected token-only usage")
        }
        XCTAssertFalse(values.contains { $0.kind == .dollars })
        XCTAssertEqual(values.first { $0.kind == .count }?.number, 240)
    }

    func testSharedOnlyLocalDetectionUsesCopilotAttributionWithoutNetwork() async throws {
        for source in ["pi", "omp"] {
            for providerID in ["github-copilot", "copilot", "anthropic"] {
                var collection = sharedCollection()
                collection.records[0].sourceID = source
                collection.records[0].providerID = providerID
                collection.records[0].recordedCostUSD = nil
                let provider = try makeSharedOnlyProvider(collection: collection)

                let detected = await provider.hasLocalCredentials()

                XCTAssertEqual(detected, providerID != "anthropic")
            }
        }
    }

    func testPositiveEstimatedAndCreditEquivalentSharedCostsKeepOnlyTokens() async throws {
        for origin in [UsageRecord.CostOrigin.estimated, .creditEquivalent] {
            var collection = sharedCollection()
            collection.records[0].recordedCostUSD = 9
            collection.records[0].costOrigin = origin
            let provider = try makeProvider(
                sqlite: .init(payload: "[]"), collector: CopilotSharedUsageCollector(collection: collection)
            )
            let snapshot = await provider.refresh()
            let history = try XCTUnwrap(snapshot.usageHistory)
            XCTAssertEqual(history.series.daily.first?.totalTokens, 120)
            XCTAssertNil(history.series.daily.first?.costUSD)
            XCTAssertNil(history.modelUsage?.daily.first?.models.first?.costUSD)
            guard case .values(_, let values, _, _, _, _) = try XCTUnwrap(snapshot.line(label: "Today")) else {
                return XCTFail("Expected token-only usage")
            }
            XCTAssertFalse(values.contains { $0.kind == .dollars })
            XCTAssertEqual(values.first { $0.kind == .count }?.number, 120)
        }
    }

    func testEmptyRejectedAndExpiredSharedRecordsDoNotAutoEnableCopilot() async throws {
        var invalid = sharedCollection()
        invalid.records[0].issues = [.invalidNumbers]
        var expired = sharedCollection()
        expired.records[0].timestamp = now.addingTimeInterval(-40 * 86_400)
        let empty = UsageCollection(records: [], sources: [.init(sourceID: "pi", completedStores: 1)])
        let failed = UsageCollection(records: [], sources: [.init(sourceID: "pi", failedStores: 1)])
        for collection in [empty, failed, invalid, expired] {
            let provider = try makeSharedOnlyProvider(collection: collection)
            let detected = await provider.hasLocalCredentials()
            XCTAssertFalse(detected)
        }
    }

    private func makeSharedOnlyProvider(collection: UsageCollection) throws -> CopilotProvider {
        let suite = "CopilotSharedUsageTests.detection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let http = RoutingHTTPClient { _ in
            XCTFail("Local detection must not request quota")
            throw URLError(.badServerResponse)
        }
        let now = now
        return CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: http),
            usageScanner: CopilotUsageScanner(sqlite: CopilotSharedUsageSQLite(payload: nil), databasePath: { nil }),
            sharedUsage: .init(collectors: [CopilotSharedUsageCollector(collection: collection)]),
            defaults: defaults, now: { now }
        )
    }

    private func sharedCollection() -> UsageCollection {
        UsageCollection(records: [UsageRecord(
            sourceID: "pi", formatID: "fixture", id: "shared-request", kind: "message",
            timestamp: now.addingTimeInterval(-60), providerID: "github-copilot", model: "fixture-shared",
            totalTokens: 120, recordedCostUSD: 0.02
        )], sources: [UsageSourceState(sourceID: "pi", completedStores: 1)])
    }

    private func makeProvider(
        sqlite: CopilotSharedUsageSQLite, collector: CopilotSharedUsageCollector, quotaStatus: Int = 200
    ) throws -> CopilotProvider {
        let suite = "CopilotSharedUsageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let body: [String: Any] = [
            "copilot_plan": "pro",
            "quota_snapshots": ["premium_interactions": ["entitlement": 100, "remaining": 75]]
        ]
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: quotaStatus, headers: [:], body: try JSONSerialization.data(withJSONObject: body)
        ))
        let now = now
        return CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{"github.com":{"oauth_token":"fixture-token"}}"#
            ]), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: http),
            usageScanner: CopilotUsageScanner(sqlite: sqlite, databasePath: { "/fixture/copilot/session-store.db" }),
            sharedUsage: .init(collectors: [collector]), defaults: defaults, now: { now }
        )
    }
}

private actor CopilotSharedUsageCollector: UsageCollecting {
    let collection: UsageCollection
    private(set) var calls = 0

    init(collection: UsageCollection) { self.collection = collection }

    func collect(since: Date) async -> UsageCollection? {
        calls += 1
        return collection
    }
}

private struct CopilotSharedUsageSQLite: SQLiteAccessing {
    let payload: String?

    func queryValue(path: String, sql: String) throws -> String? {
        guard let payload else { throw SQLiteError.queryFailed("fixture read failure") }
        return payload
    }

    func execute(path: String, sql: String) throws {
        XCTFail("Usage history must not write to SQLite")
    }
}
