import XCTest
@testable import OpenUsage

@MainActor
final class CopilotUsageIntegrationTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 12))!

    func testRefreshContributesLocalHistoryToEveryTotalSpendPeriod() async throws {
        let fixture = try makeFixture(rows: [
            row(daysAgo: 0, input: 1_000, output: 500, nanoAIU: 250_000_000),
            row(daysAgo: 0, input: 500, output: 500, nanoAIU: 50_000_000),
            row(daysAgo: 1, input: 2_000, output: 1_000, nanoAIU: 20_000_000_000),
            row(daysAgo: 30, input: 4_000, output: 1_000, nanoAIU: 100_000_000_000),
            row(daysAgo: 31, input: 9_000, output: 1_000, nanoAIU: 900_000_000_000)
        ])

        await fixture.store.refreshAll(force: true)

        let snapshot = try XCTUnwrap(fixture.store.snapshots["copilot"])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(fixture.layout.spendCapableProviders.map(\.id), ["copilot"])
        XCTAssertTrue(fixture.layout.hasSpendCapableProvider)
        let expected: [(TotalSpendPeriod, Double, Double)] = [
            (.today, 0.003, 2_500), (.yesterday, 0.2, 3_000), (.last30, 1.203, 10_500)
        ]
        for (period, cost, tokens) in expected {
            let total = total(fixture, period: period)
            XCTAssertEqual(total.slices.map(\.id), ["copilot"])
            XCTAssertEqual(total.totalUSD, cost, accuracy: 0.0000001)
            XCTAssertEqual(total.totalTokens, tokens)
            XCTAssertFalse(total.isEstimated)
            XCTAssertEqual(total.projection(for: .cost).centerValue, cost, accuracy: 0.0000001)
            XCTAssertEqual(total.projection(for: .tokens).centerValue, tokens)
            XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, cost / tokens * 1_000_000, accuracy: 0.0000001)
        }
        XCTAssertFalse(total(fixture).projection(for: .cost).isEmpty, "Sub-cent usage must remain in Cost")
    }

    func testLocalHistorySurvivesMissingTokenInvalidTokenAndNetworkFailure() async throws {
        let unavailable = RoutingHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let unauthorized = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let cases: [(Bool, any HTTPClient)] = [(false, unauthorized), (true, unauthorized), (true, unavailable)]
        for (signedIn, http) in cases {
            let fixture = try makeFixture(rows: [row()], signedIn: signedIn, quotaHTTP: http)

            await fixture.store.refreshAll(force: true)

            let snapshot = try XCTUnwrap(fixture.store.snapshots["copilot"])
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.authenticationIssue)
            XCTAssertNil(fixture.store.providerErrors["copilot"])
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertTrue(snapshot.warning?.contains("Local CLI history is still available") == true)
            XCTAssertNotNil(snapshot.usageHistory)
            XCTAssertEqual(total(fixture).totalUSD, 0.003, accuracy: 0.0000001)
            XCTAssertEqual(total(fixture).totalTokens, 1_500)
        }
    }

    func testScannerFailureKeepsQuotaAndWarnsWithoutInventingHistory() async throws {
        let fixture = try makeFixture()
        fixture.sqlite.failReads = true

        await fixture.store.refreshAll(force: true)

        let snapshot = try XCTUnwrap(fixture.store.snapshots["copilot"])
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertTrue(snapshot.warning?.contains("Couldn't read Copilot CLI usage history") == true)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertTrue(total(fixture).isEmpty)
    }

    func testLocalCLIStoreCanBeDetectedWithoutQuotaCredentialsOrNetworkRequests() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let fixture = try makeFixture(signedIn: false, quotaHTTP: http)
        let detected = await fixture.provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        XCTAssertTrue(http.requests.isEmpty)

        let absent = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: http),
            usageScanner: .init(databasePath: { nil })
        )
        let missing = await absent.hasLocalCredentials()
        XCTAssertFalse(missing)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testFailedScanPreservesLastGoodHistoryAndSuccessfulEmptyScanClearsIt() async throws {
        let fixture = try makeFixture(rows: [row()])
        await fixture.store.refreshAll(force: true)
        let history = try XCTUnwrap(fixture.store.localSnapshots["copilot"]?.usageHistory)

        fixture.sqlite.failReads = true
        await fixture.store.refreshAll(force: true)

        XCTAssertEqual(fixture.store.localSnapshots["copilot"]?.usageHistory, history)
        XCTAssertNotNil(fixture.store.snapshots["copilot"]?.warning)
        XCTAssertEqual(fixture.cache.snapshot(providerID: "copilot")?.usageHistory, history)
        XCTAssertEqual(total(fixture).totalUSD, 0.003, accuracy: 0.0000001)

        fixture.sqlite.failReads = false
        fixture.sqlite.json = "[]"
        await fixture.store.refreshAll(force: true)

        let empty = try XCTUnwrap(fixture.store.localSnapshots["copilot"]?.usageHistory)
        XCTAssertTrue(empty.series.daily.isEmpty)
        XCTAssertNil(fixture.store.snapshots["copilot"]?.warning)
        XCTAssertNil(fixture.store.snapshots["copilot"]?.line(label: "Today"))
        XCTAssertEqual(fixture.cache.snapshot(providerID: "copilot")?.usageHistory, empty)
        XCTAssertTrue(total(fixture).isEmpty)
    }

    func testUsageHistoryDoesNotAddMetricsOrChangeExistingPlacement() throws {
        let fixture = try makeFixture()
        let ids = ["copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend", "copilot.chat", "copilot.completions"]
        XCTAssertEqual(fixture.provider.widgetDescriptors.map(\.id), ids)
        XCTAssertEqual(fixture.layout.visiblePlaced.map(\.descriptorID), ids)
        XCTAssertEqual(fixture.layout.pinnedGroups.flatMap(\.metrics).map(\.id), ["copilot.premium"])
        XCTAssertEqual(fixture.layout.displayGroups.first?.alwaysShownWidgets.map(\.descriptorID), Array(ids.prefix(2)))
        XCTAssertEqual(fixture.layout.displayGroups.first?.expandedWidgets.map(\.descriptorID), Array(ids.dropFirst(2)))
        XCTAssertFalse(fixture.provider.widgetDescriptors.contains(where: \.isSpendTile))
        let histories = fixture.provider.widgetDescriptors.compactMap(\.historyResource)
        XCTAssertEqual(histories.count, 1)
        XCTAssertEqual(histories.first?.scope, .machineLocal)
        XCTAssertEqual(histories.first?.estimatedCost, false)
    }

    func testOrganizationSpendIsExcludedFromPersonalTotalSpend() async throws {
        let quota = try response([
            "copilot_plan": "business", "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["entitlement": 0, "remaining": 0, "credits_used": 2111]]
        ])
        let organizations = RoutingHTTPClient { request in
            let body: Any = request.url.path == "/user/orgs"
                ? [["login": "fixture-org"]]
                : ["usageItems": [["product": "Copilot", "unitType": "ai-credits", "grossQuantity": 9_000, "netAmount": 12]]]
            return HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
        }
        let fixture = try makeFixture(rows: [row()], quotaHTTP: FakeHTTPClient(response: quota), orgHTTP: organizations)

        await fixture.store.refreshAll(force: true)

        let snapshot = try XCTUnwrap(fixture.store.snapshots["copilot"])
        XCTAssertNotNil(snapshot.line(label: "Org Spend"))
        XCTAssertNotNil(snapshot.line(label: "Org Credits"))
        XCTAssertEqual(total(fixture).totalUSD, 0.003, accuracy: 0.0000001)
        fixture.sqlite.json = "[]"
        await fixture.store.refreshAll(force: true)
        XCTAssertNotNil(fixture.store.snapshots["copilot"]?.line(label: "Org Spend"))
        XCTAssertTrue(total(fixture).isEmpty)
    }

    func testDisabledCopilotIsExcludedFromTotalAndHistoryExport() async throws {
        let fixture = try makeFixture(rows: [row()])
        await fixture.store.refreshAll(force: true)
        XCTAssertFalse(total(fixture).isEmpty)

        fixture.enablement.setEnabled(false, for: "copilot")

        XCTAssertTrue(fixture.layout.spendCapableProviders.isEmpty)
        XCTAssertFalse(fixture.layout.hasSpendCapableProvider)
        XCTAssertTrue(total(fixture).isEmpty)
        XCTAssertNotNil(fixture.store.localSnapshots["copilot"]?.usageHistory)
        XCTAssertNil(fixture.store.localHistoryDocument(deviceID: "local", deviceName: "Local Mac").providers["copilot"])
        fixture.enablement.setEnabled(true, for: "copilot")
        XCTAssertEqual(total(fixture).totalUSD, 0.003, accuracy: 0.0000001)
    }

    func testICloudExportContainsOnlyLocalHistoryAfterPeerAggregation() async throws {
        let fixture = try makeFixture(rows: [row()])
        await fixture.store.refreshAll(force: true)
        let localHistory = try XCTUnwrap(fixture.store.localSnapshots["copilot"]?.usageHistory)
        let peerHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 500, costUSD: 2)
        ]))
        fixture.store.setPeerHistoryDocuments([
            UsageHistoryDocument(deviceID: "peer", deviceName: "Peer Mac", updatedAt: now, providers: ["copilot": peerHistory])
        ], ownDeviceID: "local")

        XCTAssertEqual(total(fixture).totalUSD, 2.003, accuracy: 0.0000001)
        XCTAssertEqual(total(fixture).totalTokens, 2_000)
        let exported = fixture.store.localHistoryDocument(deviceID: "local", deviceName: "Local Mac", updatedAt: now)
        try exported.validate()
        XCTAssertEqual(exported.providers["copilot"], localHistory)
        XCTAssertNil(exported.identities)
        let decoded = try JSONDecoder().decode(UsageHistoryDocument.self, from: JSONEncoder().encode(exported))
        XCTAssertEqual(decoded.providers["copilot"], localHistory)
    }

    private struct Fixture {
        let provider: CopilotProvider
        let sqlite: CopilotIntegrationSQLite
        let store: WidgetDataStore
        let layout: LayoutStore
        let enablement: ProviderEnablementStore
        let cache: ProviderSnapshotCache
    }

    private func makeFixture(
        rows: [[Any]] = [], signedIn: Bool = true,
        quotaHTTP: (any HTTPClient)? = nil, orgHTTP: (any HTTPClient)? = nil
    ) throws -> Fixture {
        let suite = "CopilotUsageIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let sqlite = CopilotIntegrationSQLite(json: String(decoding: try JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
        let now = now
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(signedIn ? [
                CopilotAuthStore.editorAppsPath: #"{"github.com":{"oauth_token":"fixture-token"}}"#
            ] : [:]), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: try quotaHTTP ?? FakeHTTPClient(response: response([
                "copilot_plan": "pro",
                "quota_snapshots": ["premium_interactions": ["entitlement": 100, "remaining": 75]]
            ]))),
            orgBillingClient: CopilotOrgBillingClient(http: orgHTTP ?? FakeHTTPClient(
                response: HTTPResponse(statusCode: 403, headers: [:], body: Data())
            )),
            usageScanner: CopilotUsageScanner(sqlite: sqlite, databasePath: { "/fixture/copilot/session-store.db" }),
            defaults: defaults,
            now: { now }
        )
        let registry = WidgetRegistry.from([provider])
        let enablement = ProviderEnablementStore(defaults: defaults)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        let store = WidgetDataStore(
            registry: registry, providers: [provider], cache: cache, defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) }, now: { now }
        )
        enablement.onChange = { [weak store] in store?.providerEnablementDidChange() }
        let layout = LayoutStore(registry: registry, defaults: defaults, isProviderEnabled: { enablement.isEnabled($0) })
        return Fixture(provider: provider, sqlite: sqlite, store: store, layout: layout, enablement: enablement, cache: cache)
    }

    private func row(daysAgo: Int = 0, input: Int = 1_000, output: Int = 500, nanoAIU: Int = 300_000_000) -> [Any] {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
        return [ISO8601DateFormatter().string(from: date), "claude-sonnet-fixture", input, output, nanoAIU]
    }

    private func response(_ body: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
    }

    private func total(_ fixture: Fixture, period: TotalSpendPeriod = .today) -> TotalSpend {
        TotalSpendAggregator.total(for: period, providers: fixture.layout.spendCapableProviders, snapshots: fixture.store.snapshots)
    }
}

private final class CopilotIntegrationSQLite: SQLiteAccessing, @unchecked Sendable {
    var json: String
    var failReads = false

    init(json: String) { self.json = json }

    func queryValue(path: String, sql: String) throws -> String? {
        if failReads { throw SQLiteError.queryFailed("fixture read failure") }
        return json
    }

    func execute(path: String, sql: String) throws {
        XCTFail("Usage history must not write to SQLite")
    }
}
