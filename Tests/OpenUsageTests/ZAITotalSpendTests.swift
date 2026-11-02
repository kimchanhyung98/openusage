import XCTest
@testable import OpenUsage

@MainActor
final class ZAITotalSpendTests: XCTestCase {
    func testActivityFlowsThroughRefreshCapabilityAndAllDashboardPeriods() async throws {
        let runtime = provider(activity: response(activityBody))
        let snapshot = await runtime.refresh()
        let suite = "OpenUsageTests.ZAITotalSpend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let enablement = ProviderEnablementStore(defaults: defaults)
        let registry = WidgetRegistry.from([runtime])
        let layout = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout",
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        for descriptor in registry.descriptors {
            layout.setMetricEnabled(descriptor.id, false)
        }

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.plan, "GLM Coding Max")
        XCTAssertEqual(snapshot.lines.count, 1)
        XCTAssertTrue(layout.displayGroups.isEmpty)
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["zai"])
        XCTAssertTrue(runtime.provider.usesDedicatedSpendLines)
        XCTAssertEqual(registry.descriptors.count, 3)
        XCTAssertFalse(registry.descriptors.contains(where: \.isSpendTile))
        for (period, expected): (TotalSpendPeriod, Double) in [(.today, 300), (.yesterday, 200), (.last30, 600)] {
            let total = TotalSpendAggregator.total(
                for: period, providers: layout.spendCapableProviders, snapshots: ["zai": snapshot]
            )
            XCTAssertEqual(total.projection(for: .tokens).centerValue, expected)
            XCTAssertTrue(total.projection(for: .cost).isEmpty)
            XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
        }
        enablement.setEnabled(false, for: "zai")
        XCTAssertTrue(layout.spendCapableProviders.isEmpty)
    }

    func testRequestUsesPersonalScopeRawKeyAndCommonLocalDateWindow() async {
        let runtime = ZAIProvider(
            authStore: authStore(),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url.path == ZAIUsageClient.activityURL.path {
                    XCTAssertEqual(request.method, "GET")
                    XCTAssertEqual(request.url.host, "api.z.ai")
                    XCTAssertEqual(request.headers["Authorization"], "test-key")
                    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
                    XCTAssertEqual(query, [
                        "type": "1", "startTime": "2026-10-03 00:00:00", "endTime": "2026-11-02 23:59:59"
                    ])
                    return response(activityBody)
                }
                XCTAssertEqual(request.headers["Authorization"], "test-key")
                if request.url.path == ZAIUsageClient.detailURL.path { return response(emptyDetailBody) }
                return response(request.url == ZAIUsageClient.quotaURL ? quotaBody : subscriptionBody)
            }),
            now: { fixedNow }, calendar: calendar("Asia/Seoul"), pricing: { .empty }
        )

        let snapshot = await runtime.refresh()
        XCTAssertNotNil(snapshot.warning)
    }

    func testActivityHTTPAndBusinessFailuresPreserveQuotaWithWarning() async {
        let failures = [
            HTTPResponse(statusCode: 403, headers: [:], body: Data()),
            HTTPResponse(statusCode: 500, headers: [:], body: Data()),
            response(#"{"success":false,"code":500,"data":{"series":[]}}"#),
            response(#"{"success":true,"code":200,"data":{}}"#)
        ]
        for failure in failures {
            let snapshot = await provider(activity: failure).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertNotNil(snapshot.warning)
            XCTAssertNotNil(snapshot.line(label: "Session"))
            XCTAssertNil(snapshot.totalSpendLines)
            XCTAssertTrue(TotalSpendAggregator.total(
                for: .today, providers: [provider(activity: failure).provider], snapshots: ["zai": snapshot]
            ).isEmpty)
        }
    }

    func testTransportFailureDoesNotEraseQuota() async {
        let runtime = ZAIProvider(
            authStore: authStore(), usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url.path == ZAIUsageClient.activityURL.path { throw URLError(.timedOut) }
                if request.url.path == ZAIUsageClient.detailURL.path { return response(emptyDetailBody) }
                return response(request.url == ZAIUsageClient.quotaURL ? quotaBody : subscriptionBody)
            }), now: { fixedNow }, calendar: calendar("Asia/Seoul"), pricing: { .empty }
        )
        let snapshot = await runtime.refresh()

        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.totalSpendLines)
    }

    func testExplicitEmptyActivityIsSuccessfulAndDoesNotInventCost() async {
        let runtime = provider(activity: response(#"{"code":200,"success":true,"data":{"summary":{"totalTokens":0},"series":[]}}"#))
        let snapshot = await runtime.refresh()

        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.isDegraded)
        XCTAssertEqual(snapshot.totalSpendLines?.count, 3)
        for period in TotalSpendPeriod.allCases {
            XCTAssertTrue(TotalSpendAggregator.total(
                for: period, providers: [runtime.provider], snapshots: ["zai": snapshot]
            ).isEmpty)
        }
    }

    func testInvalidQuotaDoesNotRequestActivity() async {
        let runtime = ZAIProvider(
            authStore: authStore(), usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                XCTAssertNotEqual(request.url.path, ZAIUsageClient.activityURL.path)
                return response(request.url == ZAIUsageClient.quotaURL ? "{}" : subscriptionBody)
            }), pricing: { .empty }
        )
        let snapshot = await runtime.refresh()
        XCTAssertNotNil(snapshot.errorCategory)
    }

    private func provider(activity: HTTPResponse) -> ZAIProvider {
        ZAIProvider(
            authStore: authStore(), usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url.path == ZAIUsageClient.activityURL.path { return activity }
                if request.url.path == ZAIUsageClient.detailURL.path { return response(emptyDetailBody) }
                return response(request.url == ZAIUsageClient.quotaURL ? quotaBody : subscriptionBody)
            }), now: { fixedNow }, calendar: calendar("Asia/Seoul"), pricing: { .empty }
        )
    }

    private func authStore() -> ZAIAuthStore {
        ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "test-key"]))
    }
}

final class ZAIActivityMapperTests: XCTestCase {
    func testUsesDailySeriesWithoutAssumingSummaryHasTheSameTimeRange() throws {
        let body = activityBody.replacingOccurrences(of: "\"totalTokens\":600", with: "\"totalTokens\":999999")
        let lines = try ZAIActivityMapper.map(
            Data(body.utf8), window: ZAIActivityWindow(now: fixedNow, calendar: calendar("Asia/Seoul"))
        )
        XCTAssertEqual(lines.last, .values(
            label: "Last 30 Days", values: [MetricValue(number: 600, kind: .count, label: "tokens")]
        ))
    }

    func testAcceptsBothOfficialSuccessCodes() throws {
        for code in [0, 200] {
            let body = activityBody.replacingOccurrences(of: "\"code\":200", with: "\"code\":\(code)")
            let lines = try ZAIActivityMapper.map(
                Data(body.utf8), window: ZAIActivityWindow(now: fixedNow, calendar: calendar("Asia/Seoul"))
            )
            XCTAssertEqual(lines.count, 3)
        }
    }

    func testRejectsIncompleteInvalidDuplicateAndOutOfRangeSeries() {
        let rows = [
            #"[{"date":"2026-11-02"}]"#,
            #"[{"date":"2026-11-02","totalTokens":null}]"#,
            #"[{"date":"2026-11-02","totalTokens":true}]"#,
            #"[{"date":"2026-11-02","totalTokens":-1}]"#,
            #"[{"date":"2026-11-02","totalTokens":1.5}]"#,
            #"[{"date":"2026-11-02","totalTokens":1e309}]"#,
            #"[{"date":"2026-11-02","totalTokens":9223372036854775808}]"#,
            #"[{"date":"2026-11-02","totalTokens":1},{"date":"2026-11-02","totalTokens":1}]"#,
            #"[{"date":"2026-11-02","totalTokens":1},{"date":"2026-11-02","totalTokens":2}]"#,
            #"[{"date":"2026-10-02","totalTokens":1}]"#,
            #"[{"date":"2026-11-03","totalTokens":1}]"#,
            #"[{"date":"2026-10-32","totalTokens":1}]"#,
            #"[{"date":"2026-11-02T00:00:00Z","totalTokens":1}]"#,
            #"[{"date":"2026-11-01","totalTokens":9223372036854775807},{"date":"2026-11-02","totalTokens":1}]"#
        ]
        for row in rows {
            assertInvalid(#"{"data":{"series":\#(row)}}"#)
        }
        for body in [
            #"{"data":{"series":null}}"#,
            #"{"data":{"series":{},"summary":{"totalTokens":0}}}"#,
            #"{"code":500,"data":{"series":[]}}"#,
            #"{"success":false,"data":{"series":[]}}"#
        ] { assertInvalid(body) }
    }

    func testDateWindowUsesCalendarDaysAcrossDSTAndNonWholeHourOffset() {
        let examples = [
            ("2026-03-09T00:30:00Z", "America/New_York", "2026-02-06 00:00:00", "2026-03-08 23:59:59"),
            ("2026-11-02T00:30:00Z", "America/New_York", "2026-10-02 00:00:00", "2026-11-01 23:59:59"),
            ("2026-11-01T18:30:00Z", "Asia/Kathmandu", "2026-10-03 00:00:00", "2026-11-02 23:59:59")
        ]
        for (now, zone, start, end) in examples {
            let window = ZAIActivityWindow(now: OpenUsageISO8601.date(from: now)!, calendar: calendar(zone))
            XCTAssertEqual(window.days.count, UsageHistoryWindow.previousDays + 1)
            XCTAssertEqual(window.startTime, start)
            XCTAssertEqual(window.endTime, end)
        }
    }

    private func assertInvalid(_ body: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ZAIActivityMapper.map(
            Data(body.utf8), window: ZAIActivityWindow(now: fixedNow, calendar: calendar("Asia/Seoul"))
        ), file: file, line: line) { error in
            XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, file: file, line: line)
        }
    }
}

private var fixedNow: Date { OpenUsageISO8601.date(from: "2026-11-01T15:30:00Z")! }
private let quotaBody = #"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12}]}}"#
private let emptyDetailBody = #"{"data":{"modelUsage":{"xTime":[],"modelDataList":[]}}}"#
private let subscriptionBody = #"{"data":[{"productName":"GLM Coding Max"}]}"#
private let activityBody = #"""
{"code":200,"success":true,"data":{"summary":{"totalTokens":600},"series":[
{"date":"2026-11-02","totalTokens":300,"modelCallCount":5,"mcpCalls":2},
{"date":"2026-10-03","totalTokens":100},
{"date":"2026-11-01","totalTokens":200}
]}}
"""#

private func response(_ body: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
}

private func calendar(_ timeZone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    return calendar
}
