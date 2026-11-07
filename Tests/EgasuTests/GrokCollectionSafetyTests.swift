import XCTest
@testable import Egasu

@MainActor
final class GrokCollectionSafetyTests: XCTestCase {
    private let instant = EgasuISO8601.date(from: "2026-11-01T12:00:00Z")!

    func testUnreadableNativeLogKeepsSharedUsageAndWarns() async {
        let files = GrokCollectionFiles()
        files.unreadable = true
        let record = UsageRecordFixture.record(
            timestamp: instant, providerID: "grok", model: "grok-build", cost: 0.25,
            tokens: TokenBreakdown(input: 100), total: 100
        )
        let provider = makeProvider(files: files, records: [record])

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(snapshot.warning, "Some local usage files could not be read. Usage history may be incomplete.")
        XCTAssertNil(snapshot.errorCategory)
    }

    func testTotalReadFailurePreservesLastGoodHistoryAndRecovers() async throws {
        let files = GrokCollectionFiles()
        let provider = makeProvider(files: files)
        let suite = "EgasuTests.GrokCollectionSafety." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = instant
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { now })
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults, now: { now }
        )
        var degradation: [Bool] = []
        store.onRefreshOutcome = { _, _, _, _, degraded in degradation.append(degraded) }
        _ = await store.refresh(providerID: "grok", force: true)
        let initial = try XCTUnwrap(store.localSnapshots["grok"]?.usageHistory)
        XCTAssertEqual(initial.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(degradation, [false])

        files.unreadable = true
        _ = await store.refresh(providerID: "grok", force: true)

        let retained = try XCTUnwrap(store.localSnapshots["grok"])
        XCTAssertEqual(retained.usageHistory, initial)
        XCTAssertEqual(degradation, [false, true])
        XCTAssertEqual(retained.warning, "Some local usage files could not be read. Usage history may be incomplete.")
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["grok"])["grok"]?.usageHistory, initial)

        files.unreadable = false
        _ = await store.refresh(providerID: "grok", force: true)

        XCTAssertNil(store.localSnapshots["grok"]?.warning)
        XCTAssertEqual(store.localSnapshots["grok"]?.usageHistory, initial)
        XCTAssertEqual(degradation, [false, true, false])
    }

    func testUnsupportedAuthNeverReachesSubscriptionAPI() async {
        let http = GrokCollectionHTTP()
        let auth = FakeFiles([GrokAuthStore.authPath: #"{"xai::api_key":{"key":"api","auth_mode":"api_key"}}"#])
        let provider = makeProvider(files: GrokCollectionFiles(), auth: auth, http: http)

        let hasCredentials = await provider.hasLocalCredentials()
        XCTAssertFalse(hasCredentials)
        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 0)
    }

    private func makeProvider(
        files: GrokCollectionFiles, records: [UsageRecord] = [],
        auth: FakeFiles? = nil, http: GrokCollectionHTTP = GrokCollectionHTTP()
    ) -> GrokProvider {
        let now = instant
        let authFiles = auth ?? FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","expires_at":"2099-01-01T00:00:00Z"}}"#
        ])
        return GrokProvider(
            authStore: GrokAuthStore(files: authFiles, environment: FakeEnvironment(), now: { now }),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(
                files: files, environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/fixture/grok-collection-safety") }
            ),
            sharedUsage: UsageCollectionCoordinator(collectors: [GrokCollectionStub(records: records)]),
            now: { now }, pricing: { TestPricing.bundled }
        )
    }
}

private struct GrokCollectionStub: UsageCollecting {
    let records: [UsageRecord]

    func collect(since: Date) async -> UsageCollection? { UsageCollection(records: records) }
}

private final class GrokCollectionHTTP: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(
            statusCode: 200, headers: [:],
            body: request.url == GrokUsageClient.creditsConfigURL ? GrokCreditsFixtures.capturedResponseBody : Data("{}".utf8)
        )
    }
}

private final class GrokCollectionFiles: TextFileAccessing, @unchecked Sendable {
    var unreadable = false

    func exists(_ path: String) -> Bool { path.hasSuffix("/logs/unified.jsonl") }

    func readText(_ path: String) throws -> String {
        if unreadable { throw CocoaError(.fileReadNoPermission) }
        return """
        {"ts":"2026-11-01T09:00:00Z","pid":1,"sid":"s","msg":"backend_search: model switch","ctx":{"model_id":"grok-build","api_backend":"Responses"}}
        {"ts":"2026-11-01T09:01:00Z","pid":1,"sid":"s","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100,"completion_tokens":20}}
        """
    }

    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
}
