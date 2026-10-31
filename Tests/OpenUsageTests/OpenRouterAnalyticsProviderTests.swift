import XCTest
@testable import OpenUsage

@MainActor
final class OpenRouterAnalyticsProviderTests: XCTestCase {
    private let now = fixtureDate("2026-10-21T12:34:56Z")
    private let warning = "Some OpenRouter statistics are unavailable. Other usage data is still available."

    func testManagementKeyUsesAccountAnalyticsForVisibleAndTopPeriods() async throws {
        let expected: [Date: (label: String, cost: Double, tokens: Int)] = [
            fixtureDate("2026-10-20T15:00:00Z"): ("Today", 1, 100),
            fixtureDate("2026-10-19T15:00:00Z"): ("Yesterday", 2, 200),
            fixtureDate("2026-09-20T15:00:00Z"): ("Last 30 Days", 3, 300),
            fixtureDate("2026-10-18T15:00:00Z"): ("This Week", 4, 400),
            fixtureDate("2026-09-30T15:00:00Z"): ("This Month", 5, 500)
        ]
        for flag in ["is_management_key", "is_provisioning_key"] {
            let http = AnalyticsProviderHTTP(key: keyResponse(flag: flag)) { request in
                let value = try XCTUnwrap(expected[try requestedRange(request).start])
                return analyticsResponse(cost: value.cost, tokens: String(value.tokens))
            }
            let provider = makeProvider(http: http)

            let snapshot = await provider.refresh()

            XCTAssertEqual(snapshot.plan, "Pay as you go")
            XCTAssertEqual(snapshot.refreshedAt, now)
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.warning)
            XCTAssertNil(snapshot.isDegraded)
            XCTAssertNil(snapshot.usageHistory)
            XCTAssertNotNil(snapshot.line(label: "Credits"))
            XCTAssertEqual(snapshot.line(label: "Key Limit"), .progress(label: "Key Limit", used: 2, limit: 5, format: .dollars))
            for value in expected.values {
                let lines = ["Today", "Yesterday", "Last 30 Days"].contains(value.label)
                    ? snapshot.totalSpendLines ?? [] : snapshot.lines
                XCTAssertEqual(metric(lines, label: value.label, kind: .dollars), value.cost)
                XCTAssertEqual(metric(lines, label: value.label, kind: .count), Double(value.tokens))
            }
            XCTAssertEqual(metric(snapshot.lines, label: "Today", kind: .dollars), 1)
            XCTAssertNil(snapshot.line(label: "Yesterday"))
            XCTAssertNil(snapshot.line(label: "Last 30 Days"))
            XCTAssertEqual(Set(snapshot.totalSpendLines?.map(\.label) ?? []), ["Today", "Yesterday", "Last 30 Days"])
            let requests = await http.requests
            let analytics = requests.filter { $0.url.absoluteString == OpenRouterUsageClient.analyticsURL }
            XCTAssertEqual(analytics.count, 5)
            XCTAssertEqual(Set(try analytics.map { try requestedRange($0).start }), Set(expected.keys))
            for request in analytics {
                let range = try requestedRange(request)
                let expectedEnd = range.start == fixtureDate("2026-10-19T15:00:00Z")
                    ? fixtureDate("2026-10-20T15:00:00Z") : now
                XCTAssertEqual(range.end, expectedEnd)
                XCTAssertEqual(request.headers["Authorization"], "Bearer fixture")
            }
        }
    }

    func testNormalKeyKeepsKeySpendWithoutRequestingAccountAnalytics() async {
        let http = AnalyticsProviderHTTP(key: jsonResponse(["data": [
            "is_management_key": false, "is_provisioning_key": false,
            "usage_daily": 1, "usage_weekly": 2, "usage_monthly": 3
        ]])) { _ in
            XCTFail("ordinary keys must not request account analytics")
            return analyticsResponse(cost: 99, tokens: "999")
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(metric(snapshot.lines, label: "Today", kind: .dollars), 1)
        XCTAssertEqual(metric(snapshot.lines, label: "This Week", kind: .dollars), 2)
        XCTAssertEqual(metric(snapshot.lines, label: "This Month", kind: .dollars), 3)
        XCTAssertEqual(snapshot.totalSpendLines, [])
        XCTAssertNil(snapshot.warning)
        let requests = await http.requests
        XCTAssertEqual(Set(requests.map { $0.url.absoluteString }), [OpenRouterUsageClient.creditsURL, OpenRouterUsageClient.keyURL])
        XCTAssertEqual(requests.count, 2)
    }

    func testMissingKeyNeverContactsAnalyticsOrOtherEndpoints() async {
        let http = AnalyticsProviderHTTP { _ in
            XCTFail("missing credentials must not contact the server")
            return analyticsResponse(cost: 1, tokens: "1")
        }
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: OpenRouterUsageClient(http: http)
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        let requests = await http.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testUnavailableKeyMetadataPreservesCreditsAndWarnsAboutUnavailableStatistics() async {
        for status in [403, 503, 200] {
            let http = AnalyticsProviderHTTP(key: HTTPResponse(statusCode: status, headers: [:], body: Data("{}".utf8))) { _ in
                XCTFail("unknown key type must not request account analytics")
                return analyticsResponse(cost: 99, tokens: "999")
            }

            let snapshot = await makeProvider(http: http).refresh()

            XCTAssertEqual(Set(snapshot.lines.map(\.label)), ["Credits", "Balance"])
            XCTAssertEqual(snapshot.totalSpendLines, [])
            XCTAssertEqual(snapshot.warning, warning)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.authenticationIssue)
            let requests = await http.requests
            XCTAssertEqual(requests.count, 2)
        }
    }

    func testMeasuredZeroAnalyticsRemainAvailableWithoutWarning() async {
        let http = AnalyticsProviderHTTP { _ in analyticsResponse(cost: 0, tokens: "0") }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(snapshot.totalSpendLines?.count, 3)
        for label in ["Today", "Yesterday", "Last 30 Days"] {
            XCTAssertEqual(metric(snapshot.totalSpendLines ?? [], label: label, kind: .dollars), 0)
            XCTAssertEqual(metric(snapshot.totalSpendLines ?? [], label: label, kind: .count), 0)
        }
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.isDegraded)
    }

    func testCostOnlyAnalyticsPreserveCostAndReportUnavailableTokens() async {
        let http = AnalyticsProviderHTTP { _ in analyticsResponse(cost: 2.5, tokens: NSNull()) }

        let snapshot = await makeProvider(http: http).refresh()

        for label in ["Today", "Yesterday", "Last 30 Days"] {
            XCTAssertEqual(metric(snapshot.totalSpendLines ?? [], label: label, kind: .dollars), 2.5)
            XCTAssertNil(metric(snapshot.totalSpendLines ?? [], label: label, kind: .count))
        }
        XCTAssertEqual(metric(snapshot.lines, label: "Today", kind: .dollars), 2.5)
        XCTAssertEqual(snapshot.warning, warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testFailedTodayDoesNotFallBackToManagementKeyZeroOrRemoveOtherPeriods() async {
        let http = AnalyticsProviderHTTP { request in
            if try requestedRange(request).start == fixtureDate("2026-10-20T15:00:00Z") {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return analyticsResponse(cost: 4, tokens: "400")
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNil(metric(snapshot.totalSpendLines ?? [], label: "Today", kind: .dollars))
        XCTAssertEqual(Set(snapshot.totalSpendLines?.map(\.label) ?? []), ["Yesterday", "Last 30 Days"])
        XCTAssertEqual(metric(snapshot.lines, label: "This Week", kind: .dollars), 4)
        XCTAssertEqual(metric(snapshot.lines, label: "This Month", kind: .dollars), 4)
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertNotNil(snapshot.line(label: "Balance"))
        XCTAssertNotNil(snapshot.line(label: "Key Limit"))
        XCTAssertEqual(snapshot.warning, warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.authenticationIssue)
    }

    func testTruncatedPeriodIsExcludedWhileCompletePeriodsRemain() async {
        let http = AnalyticsProviderHTTP { request in
            let truncated = try requestedRange(request).start == fixtureDate("2026-09-20T15:00:00Z")
            return analyticsResponse(cost: 1, tokens: "100", truncated: truncated)
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(Set(snapshot.totalSpendLines?.map(\.label) ?? []), ["Today", "Yesterday"])
        XCTAssertEqual(snapshot.warning, warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testAllAnalyticsForbiddenKeepsCreditsAndLimitWithoutInventingPeriodZeros() async {
        let http = AnalyticsProviderHTTP { _ in
            HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(Set(snapshot.lines.map(\.label)), ["Credits", "Balance", "Key Limit"])
        XCTAssertEqual(snapshot.totalSpendLines, [])
        XCTAssertEqual(snapshot.warning, warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.authenticationIssue)
    }

    func testLaterRefreshClearsPartialWarningAndReplacesTotals() async {
        let http = AnalyticsProviderHTTP { _ in analyticsResponse(cost: 1, tokens: NSNull()) }
        let provider = makeProvider(http: http)
        let partial = await provider.refresh()
        XCTAssertEqual(partial.warning, warning)

        await http.setAnalytics { _ in analyticsResponse(cost: 2, tokens: "200") }
        let recovered = await provider.refresh()

        XCTAssertNil(recovered.warning)
        XCTAssertNil(recovered.isDegraded)
        XCTAssertEqual(metric(recovered.totalSpendLines ?? [], label: "Today", kind: .dollars), 2)
        XCTAssertEqual(metric(recovered.totalSpendLines ?? [], label: "Today", kind: .count), 200)
    }

    func testCredentialChangeDoesNotRestorePriorAccountTotalsThroughSnapshotCache() async throws {
        let suite = "OpenRouterAnalyticsProviderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let files = FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"old-account"}"#])
        let http = AnalyticsProviderHTTP { request in
            if request.headers["Authorization"] == "Bearer old-account" {
                return analyticsResponse(cost: 9, tokens: "900")
            }
            return HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }
        let provider = makeProvider(http: http, files: files)
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let initial = try XCTUnwrap(store.localSnapshots["openrouter"])
        XCTAssertEqual(metric(initial.totalSpendLines ?? [], label: "Today", kind: .dollars), 9)

        try provider.saveAPIKey("new-account")
        _ = await store.refresh(providerID: "openrouter", force: true)

        let changed = try XCTUnwrap(store.localSnapshots["openrouter"])
        XCTAssertEqual(changed.totalSpendLines, [])
        XCTAssertNil(changed.line(label: "Today"))
        XCTAssertNotNil(changed.line(label: "Balance"))
        XCTAssertEqual(changed.warning, warning)
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["openrouter"])["openrouter"]?.totalSpendLines, [])
        XCTAssertNil(store.providerErrors["openrouter"])
    }

    func testSameDayWeekAndMonthBoundsReuseOneAnalyticsRequest() async throws {
        let juneFirst = fixtureDate("2026-06-01T05:00:00Z")
        let http = AnalyticsProviderHTTP { _ in analyticsResponse(cost: 3, tokens: "300") }
        let provider = makeProvider(http: http, instant: juneFirst)

        let snapshot = await provider.refresh()

        let requests = await http.requests
        let analytics = requests.filter { $0.url.absoluteString == OpenRouterUsageClient.analyticsURL }
        XCTAssertEqual(analytics.count, 3)
        XCTAssertEqual(Set(try analytics.map { try requestedRange($0) }).count, 3)
        for label in ["Today", "This Week", "This Month"] {
            XCTAssertEqual(metric(snapshot.lines, label: label, kind: .dollars), 3)
        }
        XCTAssertEqual(snapshot.totalSpendLines?.count, 3)
    }

    func testCancellingAnalyticsRefreshPreservesLastGoodSnapshotWithoutPublishingPartialData() async throws {
        let suite = "OpenRouterAnalyticsCancellationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = AnalyticsProviderHTTP { _ in analyticsResponse(cost: 7, tokens: "700") }
        let provider = makeProvider(http: http)
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let initial = try XCTUnwrap(store.localSnapshots["openrouter"])
        let started = expectation(description: "All analytics queries started")
        started.expectedFulfillmentCount = 5
        let cancelled = expectation(description: "All analytics queries cancelled")
        cancelled.expectedFulfillmentCount = 5
        await http.setAnalytics { _ in
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                cancelled.fulfill()
                throw error
            }
            return analyticsResponse(cost: 99, tokens: "9900")
        }
        store.onFreshSnapshot = { _, _, _ in XCTFail("cancelled refresh must not publish a snapshot") }
        let task = Task { await store.refresh(providerID: "openrouter", force: true) }
        await fulfillment(of: [started], timeout: 2)

        task.cancel()
        let outcome = await task.value
        await fulfillment(of: [cancelled], timeout: 2)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(store.localSnapshots["openrouter"], initial)
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["openrouter"])["openrouter"], initial)
        XCTAssertNil(store.providerErrors["openrouter"])
        XCTAssertFalse(store.refreshingProviderIDs.contains("openrouter"))
    }

    private func makeProvider(
        http: any HTTPClient,
        files: FakeFiles = FakeFiles(),
        instant: Date? = nil
    ) -> OpenRouterProvider {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 2
        let instant = instant ?? now
        return OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "fixture"])),
            usageClient: OpenRouterUsageClient(http: http),
            now: { instant },
            calendar: calendar
        )
    }
}

private actor AnalyticsProviderHTTP: HTTPClient {
    private(set) var requests: [HTTPRequest] = []
    private let key: HTTPResponse
    private var analytics: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(
        key: HTTPResponse = keyResponse(),
        analytics: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) {
        self.key = key
        self.analytics = analytics
    }

    func setAnalytics(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        analytics = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch request.url.absoluteString {
        case OpenRouterUsageClient.creditsURL:
            return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
        case OpenRouterUsageClient.keyURL:
            return key
        case OpenRouterUsageClient.analyticsURL:
            return try await analytics(request)
        default:
            XCTFail("unexpected OpenRouter endpoint")
            throw OpenRouterUsageError.invalidResponse
        }
    }
}

private func keyResponse(flag: String = "is_management_key") -> HTTPResponse {
    jsonResponse(["data": [
        flag: true, "is_free_tier": false,
        "usage_daily": 0, "usage_weekly": 0, "usage_monthly": 0,
        "limit": 5, "limit_remaining": 3
    ]])
}

private func analyticsResponse(cost: Any, tokens: Any, truncated: Bool = false) -> HTTPResponse {
    jsonResponse(["data": [
        "data": [["total_usage": cost, "tokens_total": tokens]],
        "metadata": ["row_count": 1, "truncated": truncated]
    ]])
}

private func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: object))
}

private func requestedRange(_ request: HTTPRequest) throws -> DateInterval {
    let body = try XCTUnwrap(request.body)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let range = try XCTUnwrap(object["time_range"] as? [String: String])
    let start = try XCTUnwrap(range["start"].flatMap(OpenUsageISO8601.date(from:)))
    let end = try XCTUnwrap(range["end"].flatMap(OpenUsageISO8601.date(from:)))
    return DateInterval(start: start, end: end)
}

private func fixtureDate(_ value: String) -> Date {
    OpenUsageISO8601.date(from: value)!
}

private func metric(_ lines: [MetricLine], label: String, kind: MetricKind) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
    return values.first { $0.kind == kind }?.number
}
