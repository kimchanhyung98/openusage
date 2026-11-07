import XCTest
@testable import Egasu

@MainActor
final class ZAICostTests: XCTestCase {
    func testBundledGLM45CachePricesReachDashboardTotals() async {
        for (model, cost): (String, Double) in [
            ("glm-4.5-air", 0.03), ("glm-4.5-airx", 0.22), ("glm-4.5-x", 0.45), ("glm-4.5v", 0.11)
        ] {
            let detail = detailResponse(axis: ["00:00:00"], rows: [
                modelRow(model, cached: [1_000_000], input: [0], output: [0])
            ])
            let runtime = makeProvider(http: ZAICostHTTP(today: detail), pricing: TestPricing.bundled)
            let snapshot = await runtime.refresh()
            let result = total(snapshot, runtime: runtime, period: .today)

            XCTAssertNil(snapshot.warning, model)
            XCTAssertEqual(result.projection(for: .cost).centerValue, cost, accuracy: 1e-9, model)
            XCTAssertEqual(result.projection(for: .tokens).centerValue, 1_000_000, model)
            XCTAssertEqual(result.projection(for: .costPerMtok).centerValue, cost, accuracy: 1e-9, model)
            XCTAssertTrue(result.projection(for: .cost).isEstimated, model)
        }
    }

    func testCompleteDetailSuppliesEstimatedCostAndItsOwnTokensForEveryPeriod() async throws {
        let runtime = makeProvider()
        let snapshot = await runtime.refresh()

        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        for (period, tokens, cost): (TotalSpendPeriod, Double, Double) in [
            (.today, 350_000, 0.5), (.yesterday, 150_000, 0.36), (.last30, 560_000, 1.025)
        ] {
            let total = total(snapshot, runtime: runtime, period: period)
            XCTAssertEqual(total.projection(for: .tokens).centerValue, tokens)
            XCTAssertEqual(total.projection(for: .cost).centerValue, cost, accuracy: 1e-9)
            XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, cost / tokens * 1_000_000, accuracy: 1e-9)
            XCTAssertTrue(total.projection(for: .cost).isEstimated)
            XCTAssertTrue(total.projection(for: .costPerMtok).isEstimated)
            XCTAssertFalse(total.projection(for: .tokens).isEstimated)
        }
    }

    func testTwoDetailRequestsKeepPreviousThirtyDaysAndTodaySeparate() async {
        let http = ZAICostHTTP()
        let runtime = makeProvider(http: http)
        _ = await runtime.refresh()
        let requests = await http.requests.filter { $0.url.path == ZAIUsageClient.detailURL.path }

        XCTAssertEqual(requests.count, 2)
        var periods = Set<String>()
        for request in requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.host, "api.z.ai")
            XCTAssertEqual(request.headers["Authorization"], "test-key")
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(Set(query.keys), ["type", "usageType", "startTime", "endTime"])
            XCTAssertEqual(query["type"], "1")
            XCTAssertEqual(query["usageType"], "MODEL")
            periods.insert((query["startTime"] ?? "") + " / " + (query["endTime"] ?? ""))
        }
        XCTAssertEqual(periods, [
            "2026-10-03 00:00:00 / 2026-11-01 23:59:59",
            "2026-11-02 00:00:00 / 2026-11-02 23:59:59"
        ])
    }

    func testFailedTodayKeepsYesterdayCostButUsesActivityForTodayAndCombinedWindow() async {
        let runtime = makeProvider(http: ZAICostHTTP(today: failedResponse))
        let snapshot = await runtime.refresh()

        assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
        assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .yesterday).totalUSD, 0.36, accuracy: 1e-9)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testFailedPreviousDaysKeepTodayCostAndPreserveActivityForOtherPeriods() async {
        let runtime = makeProvider(http: ZAICostHTTP(previous: failedResponse))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
        assertTokenOnly(snapshot, runtime: runtime, period: .yesterday, expected: 2_000_000)
        assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
        XCTAssertNotNil(snapshot.warning)
    }

    func testSuccessfulHTTPStatusDoesNotHideABusinessFailure() async {
        for fields: [String: Any] in [["code": 500], ["code": 200, "success": false]] {
            var body = try! JSONSerialization.jsonObject(with: todayDetail.body) as! [String: Any]
            body.merge(fields) { _, replacement in replacement }
            let detail = HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
            let runtime = makeProvider(http: ZAICostHTTP(today: detail))
            let snapshot = await runtime.refresh()
            assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
            XCTAssertNotNil(snapshot.warning)
        }
    }

    func testCodeZeroDetailUsesTheSameSuccessfulContract() async {
        var body = try! JSONSerialization.jsonObject(with: todayDetail.body) as! [String: Any]
        body["code"] = 0
        let detail = HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
        let runtime = makeProvider(http: ZAICostHTTP(today: detail))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
    }

    func testUnknownModelOnlyRemovesCostFromPeriodsContainingItsUsage() async {
        let trailingZeros = Array(repeating: 0, count: 29)
        let unknown = modelRow("glm-unknown", cached: [1] + trailingZeros, input: [2] + trailingZeros, output: [3] + trailingZeros)
        let previous = detailResponse(axis: previousAxis, rows: [previousModel, unknown])
        let runtime = makeProvider(http: ZAICostHTTP(previous: previous))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .yesterday).totalUSD, 0.36, accuracy: 1e-9)
        assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testFailedActivityKeepsCompleteDetailTokensWhenExactPricesAreUnavailable() async {
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog())
        let runtime = makeProvider(http: ZAICostHTTP(activity: failedResponse), pricing: pricing)
        let snapshot = await runtime.refresh()

        for (period, tokens): (TotalSpendPeriod, Double) in [(.today, 350_000), (.yesterday, 150_000), (.last30, 560_000)] {
            assertTokenOnly(snapshot, runtime: runtime, period: period, expected: tokens)
        }
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testFailedActivityCannotExposeMissingAxesOrAggregateOnlyDetailAsCompleteTokens() async {
        let previous = detailResponse(axis: ["2026-10-03"], rows: [
            modelRow("glm-5.3", cached: [10_000], input: [20_000], output: [30_000])
        ])
        let today = detailResponse(axis: ["00:00:00"], rows: [["modelCode": "cached_input", "totalTokensUsage": [350_000]]])
        let runtime = makeProvider(http: ZAICostHTTP(today: today, previous: previous, activity: failedResponse))
        let snapshot = await runtime.refresh()

        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertTrue(snapshot.warning?.contains("Z.ai token statistics are unavailable.") == true)
    }

    func testUnknownVariantDoesNotUseFuzzyBasePrice() async {
        for name in [nil, "GLM-5.3"] {
            var row = modelRow("glm-5.3-unknown", cached: [200_000], input: [100_000], output: [50_000])
            row["modelName"] = name
            let today = detailResponse(axis: ["00:00:00"], rows: [row])
            let runtime = makeProvider(http: ZAICostHTTP(today: today))
            let snapshot = await runtime.refresh()

            assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
            XCTAssertNil(snapshot.warning)
            XCTAssertNil(snapshot.warningPresentation)
            XCTAssertEqual(snapshot.isDegraded, true)
        }
    }

    func testUppercaseModelNameAndRegisteredAliasUseExactPublishedModelPrice() async throws {
        let alias = PricingSupplement.AliasRule(
            pattern: try NSRegularExpression(pattern: "^glm-exact-alias$"), canonical: "glm-5.3"
        )
        let pricing = fixturePricing(aliases: [alias])
        for identifier in ["GLM-5.3", "glm-exact-alias"] {
            var row = todayModel
            row.removeValue(forKey: "modelCode")
            row["modelName"] = identifier
            let runtime = makeProvider(
                http: ZAICostHTTP(today: detailResponse(axis: ["00:00:00"], rows: [row])), pricing: pricing
            )
            let snapshot = await runtime.refresh()
            XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
        }
    }

    func testExactTurboCatalogPriceWinsWithoutFuzzyBaseFallback() async {
        let turboRates = ModelRates(inputPerMillion: 8, outputPerMillion: 12, cacheWritePerMillion: 8, cacheReadPerMillion: 3)
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["zai/glm-5": standardRates]),
            secondary: PricingCatalog(entries: ["zai/glm-5-turbo": turboRates])
        )
        let row = modelRow("glm-5-turbo", cached: [200_000], input: [100_000], output: [50_000])
        let runtime = makeProvider(http: ZAICostHTTP(today: detailResponse(axis: ["00:00:00"], rows: [row])), pricing: pricing)
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 2, accuracy: 1e-9)
    }

    func testCacheDiscountMustBeExplicitWhenCachedTokensExist() async {
        var rates = standardRates
        rates.cacheReadIsExplicit = false
        let runtime = makeProvider(pricing: fixturePricing(rates: rates))
        let snapshot = await runtime.refresh()

        assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
        assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testDailyAggregateDoesNotTriggerRequestLevelLongContextTier() async {
        var rates = standardRates
        rates.inputAbove200kPerMillion = 200
        rates.outputAbove200kPerMillion = 400
        rates.cacheReadAbove200kPerMillion = 50
        rates.longContextThresholdTokens = 10
        let runtime = makeProvider(pricing: fixturePricing(rates: rates))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .last30).totalUSD, 1.025, accuracy: 1e-9)
    }

    func testAggregateBucketsAreNotAddedAgainWhenModelRowsExist() async {
        let aggregates: [[String: Any]] = [
            ["modelCode": "cached_input", "totalTokensUsage": [200_000]],
            ["modelCode": "uncached_input", "totalTokensUsage": [100_000]],
            ["modelCode": "output", "totalTokensUsage": [50_000]]
        ]
        let runtime = makeProvider(http: ZAICostHTTP(today: detailResponse(axis: ["00:00:00"], rows: [todayModel] + aggregates)))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalTokens, 350_000)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
    }

    func testAggregateOnlyDetailKeepsActivityTokensWithoutInventingAModel() async {
        let today = detailResponse(axis: ["00:00:00"], rows: [
            ["modelCode": "cached_input", "totalTokensUsage": [200_000]],
            ["modelCode": "uncached_input", "totalTokensUsage": [100_000]],
            ["modelCode": "output", "totalTokensUsage": [50_000]]
        ])
        let runtime = makeProvider(http: ZAICostHTTP(today: today))
        let snapshot = await runtime.refresh()

        assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testInvalidDetailPreservesQuotaAndActivityInsteadOfPartialDollarTotals() async {
        var missing = todayModel
        missing.removeValue(forKey: "cachedInputTokensUsage")
        var null = todayModel
        null["cachedInputTokensUsage"] = [NSNull()]
        var short = todayModel
        short["outputTokensUsage"] = []
        var negative = todayModel
        negative["uncachedInputTokensUsage"] = [-1]
        var boolean = todayModel
        boolean["cachedInputTokensUsage"] = [true]
        var fractional = todayModel
        fractional["outputTokensUsage"] = [1.5]
        var mismatched = todayModel
        mismatched["totalTokensUsage"] = [1]
        let overflow: [String: Any] = ["modelCode": "glm-5.3", "cachedInputTokensUsage": [Int.max],
                                       "uncachedInputTokensUsage": [1], "outputTokensUsage": [0]]
        let variants = [missing, null, short, negative, boolean, fractional, mismatched, overflow]
        for row in variants {
            let runtime = makeProvider(http: ZAICostHTTP(today: detailResponse(axis: ["00:00:00"], rows: [row])))
            let snapshot = await runtime.refresh()
            assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
            XCTAssertNotNil(snapshot.line(label: "Session"))
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNotNil(snapshot.warning)
        }
    }

    func testDuplicateAxesModelsAndAggregateAliasesCannotDoubleCount() async {
        let duplicateAxis = detailResponse(axis: ["00:00:00", "00:00:00"], rows: [
            modelRow("glm-5.3", cached: [1, 1], input: [1, 1], output: [1, 1])
        ])
        let duplicateModels = detailResponse(axis: ["00:00:00"], rows: [todayModel, todayModel])
        let duplicateBuckets = detailResponse(axis: ["00:00:00"], rows: [todayModel,
            ["modelCode": "cached_input", "totalTokensUsage": [200_000]],
            ["modelCode": "cachedInput", "totalTokensUsage": [200_000]]
        ])
        let mismatchedBuckets = detailResponse(axis: ["00:00:00"], rows: [todayModel,
            ["modelCode": "cached_input", "totalTokensUsage": [400_000]]
        ])
        for detail in [duplicateAxis, duplicateModels, duplicateBuckets, mismatchedBuckets] {
            let runtime = makeProvider(http: ZAICostHTTP(today: detail))
            let snapshot = await runtime.refresh()
            assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
            XCTAssertNotNil(snapshot.warning)
        }
    }

    func testDetailCannotSmuggleAnotherDateIntoTodaysHourlyWindow() async {
        let detail = detailResponse(axis: ["2026-11-01 00:00:00"], rows: [todayModel])
        let runtime = makeProvider(http: ZAICostHTTP(today: detail))
        let snapshot = await runtime.refresh()

        assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
        XCTAssertNotNil(snapshot.warning)
    }

    func testScalarModelSummaryDoesNotReplaceTheAlignedTokenBuckets() async {
        var row = todayModel
        row["totalTokens"] = 99_999_999
        let runtime = makeProvider(http: ZAICostHTTP(today: detailResponse(axis: ["00:00:00"], rows: [row])))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalTokens, 350_000)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
    }

    func testEmptyDetailWithPositiveActivityDoesNotClaimZeroCostOrZeroTokens() async {
        let empty = detailResponse(axis: [], rows: [])
        let runtime = makeProvider(http: ZAICostHTTP(today: empty, previous: empty))
        let snapshot = await runtime.refresh()

        for (period, tokens): (TotalSpendPeriod, Double) in [(.today, 3_000_000), (.yesterday, 2_000_000), (.last30, 6_000_000)] {
            assertTokenOnly(snapshot, runtime: runtime, period: period, expected: tokens)
        }
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testSparsePreviousDailyAxisKeepsYesterdayCostButPreservesCombinedActivity() async {
        let previous = detailResponse(axis: ["2026-11-01"], rows: [
            modelRow("glm-5.3", cached: [40_000], input: [50_000], output: [60_000])
        ])
        let runtime = makeProvider(http: ZAICostHTTP(previous: previous))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .yesterday).totalUSD, 0.36, accuracy: 1e-9)
        assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testMissingYesterdayAxisPreservesPositiveActivityInsteadOfClaimingZero() async {
        let previous = detailResponse(axis: ["2026-10-03"], rows: [
            modelRow("glm-5.3", cached: [10_000], input: [20_000], output: [30_000])
        ])
        let runtime = makeProvider(http: ZAICostHTTP(previous: previous))
        let snapshot = await runtime.refresh()

        assertTokenOnly(snapshot, runtime: runtime, period: .yesterday, expected: 2_000_000)
        assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testMissingElapsedOrCurrentHourlyAxisPreservesPositiveActivity() async {
        for axis in [["00:00:00", "02:00:00"], ["00:00:00", "01:00:00"]] {
            let today = detailResponse(axis: axis, rows: [
                modelRow("glm-5.3", cached: [200_000, 0], input: [100_000, 0], output: [50_000, 0])
            ])
            let runtime = makeProvider(http: ZAICostHTTP(today: today), now: costNow.addingTimeInterval(2 * 3600))
            let snapshot = await runtime.refresh()

            assertTokenOnly(snapshot, runtime: runtime, period: .today, expected: 3_000_000)
            assertTokenOnly(snapshot, runtime: runtime, period: .last30, expected: 6_000_000)
            XCTAssertEqual(total(snapshot, runtime: runtime, period: .yesterday).totalUSD, 0.36, accuracy: 1e-9)
            XCTAssertNil(snapshot.warning)
            XCTAssertNil(snapshot.warningPresentation)
            XCTAssertEqual(snapshot.isDegraded, true)
        }
    }

    func testCompleteElapsedHourlyAxisDoesNotRequireFutureHours() async {
        let today = detailResponse(axis: ["00:00:00", "01:00:00", "02:00:00"], rows: [
            modelRow("glm-5.3", cached: [200_000, 0, 0], input: [100_000, 0, 0], output: [50_000, 0, 0])
        ])
        let runtime = makeProvider(http: ZAICostHTTP(today: today), now: costNow.addingTimeInterval(2 * 3600))
        let snapshot = await runtime.refresh()

        XCTAssertEqual(total(snapshot, runtime: runtime, period: .today).totalUSD, 0.5, accuracy: 1e-9)
        XCTAssertEqual(total(snapshot, runtime: runtime, period: .last30).totalUSD, 1.025, accuracy: 1e-9)
        XCTAssertNil(snapshot.warning)
    }

    private func makeProvider(
        http: ZAICostHTTP = ZAICostHTTP(), pricing: ModelPricing = fixturePricing(), now: Date = costNow
    ) -> ZAIProvider {
        ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "test-key"])),
            usageClient: ZAIUsageClient(http: http), now: { now }, calendar: costCalendar,
            pricing: { pricing }
        )
    }

    private func total(_ snapshot: ProviderSnapshot, runtime: ZAIProvider, period: TotalSpendPeriod) -> TotalSpend {
        TotalSpendAggregator.total(for: period, providers: [runtime.provider], snapshots: ["zai": snapshot])
    }

    private func assertTokenOnly(
        _ snapshot: ProviderSnapshot, runtime: ZAIProvider, period: TotalSpendPeriod, expected: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let total = total(snapshot, runtime: runtime, period: period)
        XCTAssertEqual(total.projection(for: .tokens).centerValue, expected, file: file, line: line)
        XCTAssertTrue(total.projection(for: .cost).isEmpty, file: file, line: line)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty, file: file, line: line)
        let values = snapshot.totalSpendLines?.first { $0.label == period.lineLabel }
        if case .values(_, let values, _, _, _, _) = values {
            XCTAssertFalse(values.contains { $0.kind == .dollars }, file: file, line: line)
        }
    }
}

final class ZAIPricingResourceTests: XCTestCase {
    func testScopedGLM45RatesMatchPublishedPrices() throws {
        let pricing = TestPricing.bundled
        for (model, input, cached, output): (String, Double, Double, Double) in [
            ("glm-4.5", 0.6, 0.11, 2.2), ("glm-4.5-air", 0.2, 0.03, 1.1),
            ("glm-4.5-airx", 1.1, 0.22, 4.5), ("glm-4.5-x", 2.2, 0.45, 8.9), ("glm-4.5v", 0.6, 0.11, 1.8)
        ] {
            let rates = try XCTUnwrap(pricing.resolve(model: "zai/" + model), model)
            XCTAssertEqual(rates.inputPerMillion, input, accuracy: 1e-9, model)
            XCTAssertEqual(rates.outputPerMillion, output, accuracy: 1e-9, model)
            XCTAssertEqual(rates.cacheWritePerMillion, input, accuracy: 1e-9, model)
            XCTAssertEqual(rates.cacheReadPerMillion, cached, accuracy: 1e-9, model)
            XCTAssertTrue(rates.cacheReadIsExplicit, model)
        }
        XCTAssertEqual(try XCTUnwrap(pricing.resolve(model: "zai/glm-4.6")).cacheReadPerMillion, 0.11, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(pricing.resolve(model: "glm-5.3")).inputPerMillion, 1.4, accuracy: 1e-9)
    }
}

private actor ZAICostHTTP: HTTPClient {
    private let today: HTTPResponse
    private let previous: HTTPResponse
    private let activity: HTTPResponse
    private(set) var requests: [HTTPRequest] = []

    init(today: HTTPResponse = todayDetail, previous: HTTPResponse = previousDetail, activity: HTTPResponse = activityResponse) {
        self.today = today
        self.previous = previous
        self.activity = activity
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        switch request.url.path {
        case ZAIUsageClient.quotaURL.path:
            return jsonResponse(#"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12}]}}"#)
        case ZAIUsageClient.subscriptionURL.path:
            return jsonResponse(#"{"data":[{"productName":"GLM Coding Max"}]}"#)
        case ZAIUsageClient.activityURL.path:
            return activity
        case ZAIUsageClient.detailURL.path:
            let start = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "startTime" }?.value
            return start == "2026-11-02 00:00:00" ? today : previous
        default:
            XCTFail("unexpected request path: \(request.url.path)")
            return failedResponse
        }
    }
}

private var costNow: Date { EgasuISO8601.date(from: "2026-11-01T15:30:00Z")! }
private var costCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    return calendar
}
private var standardRates: ModelRates {
    ModelRates(inputPerMillion: 2, outputPerMillion: 4, cacheWritePerMillion: 2, cacheReadPerMillion: 0.5)
}
private func fixturePricing(rates: ModelRates = standardRates, aliases: [PricingSupplement.AliasRule] = []) -> ModelPricing {
    ModelPricing(supplement: PricingSupplement(pricing: ["glm-5.3": rates], aliasRules: aliases), primary: PricingCatalog(), secondary: PricingCatalog())
}
private var todayModel: [String: Any] {
    modelRow("glm-5.3", cached: [200_000], input: [100_000], output: [50_000])
}
private var previousModel: [String: Any] {
    let middleZeros = Array(repeating: 0, count: 28)
    return modelRow(
        "glm-5.3", cached: [10_000] + middleZeros + [40_000],
        input: [20_000] + middleZeros + [50_000], output: [30_000] + middleZeros + [60_000]
    )
}
private func modelRow(_ model: String, cached: [Int], input: [Int], output: [Int]) -> [String: Any] {
    ["modelCode": model, "cachedInputTokensUsage": cached, "uncachedInputTokensUsage": input, "outputTokensUsage": output,
     "totalTokensUsage": cached.indices.map { cached[$0] + input[$0] + output[$0] }]
}
private var todayDetail: HTTPResponse { detailResponse(axis: ["00:00:00"], rows: [todayModel]) }
private var previousAxis: [String] { (3...31).map { String(format: "2026-10-%02d", $0) } + ["2026-11-01"] }
private var previousDetail: HTTPResponse { detailResponse(axis: previousAxis, rows: [previousModel]) }
private var activityResponse: HTTPResponse {
    jsonResponse(#"{"data":{"series":[{"date":"2026-11-02","totalTokens":3000000},{"date":"2026-11-01","totalTokens":2000000},{"date":"2026-10-03","totalTokens":1000000}]}}"#)
}
private var failedResponse: HTTPResponse { HTTPResponse(statusCode: 503, headers: [:], body: Data()) }
private func detailResponse(axis: [String], rows: [[String: Any]]) -> HTTPResponse {
    let object: [String: Any] = ["code": 200, "success": true, "data": ["modelUsage": ["xTime": axis, "modelDataList": rows]]]
    return HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: object))
}
private func jsonResponse(_ body: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
}
