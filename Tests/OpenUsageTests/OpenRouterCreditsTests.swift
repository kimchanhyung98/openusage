import XCTest
@testable import OpenUsage

final class OpenRouterCreditsMapperTests: XCTestCase {
    func testMissingOrInvalidCreditTotalsDoNotBecomeZeroBalance() {
        let invalid: [Any?] = [nil, NSNull(), true, false, "bad", "NaN", "Infinity", Double.nan, Double.infinity]
        for field in ["total_credits", "total_usage"] {
            for value in invalid {
                var data: [String: Any] = ["total_credits": 100, "total_usage": 40]
                data[field] = value
                XCTAssertTrue(OpenRouterUsageMapper.creditsLines(from: data).isEmpty, "\(field): \(String(describing: value))")
            }
        }
    }

    func testNonfiniteBalanceIsRejectedAfterSubtractingFiniteTotals() {
        let lines = OpenRouterUsageMapper.creditsLines(from: [
            "total_credits": Double.greatestFiniteMagnitude,
            "total_usage": -Double.greatestFiniteMagnitude
        ])

        XCTAssertTrue(lines.isEmpty)
    }

    func testBalancePreservesMeasuredZeroAndNegativeAmount() {
        for (credits, usage, balance) in [(0.0, 0.0, 0.0), (100, 100, 0), (100, 103, -3)] {
            let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": credits, "total_usage": usage])

            XCTAssertEqual(lines.last, .values(label: "Balance", values: [MetricValue(number: balance, kind: .dollars)]))
            if credits > 0 {
                XCTAssertEqual(lines.first, .progress(label: "Credits", used: usage, limit: credits, format: .dollars))
            }
        }
    }
}

@MainActor
final class OpenRouterCreditsProviderTests: XCTestCase {
    private let warning = "Some OpenRouter statistics are unavailable. Other usage data is still available."

    func testFailedCreditsKeepValidKeyUsageAndWarn() async {
        let responses = [
            HTTPResponse(statusCode: 503, headers: [:], body: Data()),
            creditsResponse(#"{"total_usage":40}"#),
            creditsResponse(#"{"total_credits":null,"total_usage":40}"#)
        ]
        for response in responses {
            let http = RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL { return response }
                return creditsResponse(#"{"is_management_key":false,"usage_daily":1}"#)
            }

            let snapshot = await makeProvider(http: http).refresh()

            XCTAssertEqual(snapshot.lines, [.values(label: "Today", values: [MetricValue(number: 1, kind: .dollars)])])
            XCTAssertEqual(snapshot.warning, warning)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.authenticationIssue)
            XCTAssertNil(snapshot.usageHistory)
            XCTAssertEqual(snapshot.totalSpendLines, [])
        }
    }

    func testCreditsConnectionFailureKeepsKeyUsageAndWarns() async {
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                throw URLError(.notConnectedToInternet)
            }
            return creditsResponse(#"{"is_management_key":false,"usage_daily":1}"#)
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Balance"))
        XCTAssertEqual(snapshot.warning, warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testCreditsFailureKeepsManagementAnalyticsAndWarns() async {
        for status in [403, 503] {
            let http = RoutingHTTPClient { request in
                switch request.url.absoluteString {
                case OpenRouterUsageClient.creditsURL:
                    return HTTPResponse(statusCode: status, headers: [:], body: Data())
                case OpenRouterUsageClient.keyURL:
                    return creditsResponse(#"{"is_management_key":true,"usage_daily":0}"#)
                case OpenRouterUsageClient.analyticsURL:
                    return creditsResponse(#"{"data":[{"total_usage":2.5,"tokens_total":"100"}],"metadata":{"row_count":1,"truncated":false}}"#)
                default:
                    XCTFail("Unexpected endpoint")
                    throw OpenRouterUsageError.invalidResponse
                }
            }

            let snapshot = await makeProvider(http: http).refresh()

            XCTAssertNil(snapshot.line(label: "Balance"))
            XCTAssertNotNil(snapshot.line(label: "Today"))
            XCTAssertEqual(snapshot.totalSpendLines?.count, 3)
            XCTAssertEqual(snapshot.warning, warning)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertNil(snapshot.errorCategory)
        }
    }

    func testOrdinaryKeyCreditsForbiddenIsExpectedWithoutWarning() async {
        let http = RoutingHTTPClient { request in
            if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            }
            return creditsResponse(#"{"is_management_key":false,"usage_daily":0}"#)
        }

        let snapshot = await makeProvider(http: http).refresh()

        XCTAssertEqual(snapshot.lines, [.values(label: "Today", values: [MetricValue(number: 0, kind: .dollars)])])
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.isDegraded)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testInvalidCreditsWithoutOtherDataPreserveLastGoodThenRecover() async throws {
        let suite = "OpenRouterCreditsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = FakeHTTPClient(response: creditsResponse(#"{"total_credits":100,"total_usage":40}"#))
        let provider = makeProvider(http: http)
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let initial = try XCTUnwrap(store.localSnapshots["openrouter"])

        http.response = creditsResponse(#"{"total_usage":41}"#)
        let failed = await store.refresh(providerID: "openrouter", force: true)

        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(store.localSnapshots["openrouter"], initial)
        XCTAssertEqual(cache.snapshot(providerID: "openrouter"), initial)
        XCTAssertNotNil(store.providerErrors["openrouter"])
        let failure = await provider.refresh()
        XCTAssertEqual(failure.errorCategory, .decoding)
        XCTAssertNil(failure.usageHistory)

        http.response = creditsResponse(#"{"total_usage":41,"usage_daily":1}"#)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let partial = try XCTUnwrap(store.localSnapshots["openrouter"])
        XCTAssertNil(partial.line(label: "Balance"))
        XCTAssertEqual(partial.warning, warning)
        XCTAssertEqual(partial.isDegraded, true)
        XCTAssertNotNil(partial.line(label: "Today"))

        http.response = creditsResponse(#"{"total_credits":100,"total_usage":45,"usage_daily":2}"#)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let recovered = try XCTUnwrap(store.localSnapshots["openrouter"])
        XCTAssertEqual(recovered.line(label: "Balance"), .values(label: "Balance", values: [MetricValue(number: 55, kind: .dollars)]))
        XCTAssertNil(recovered.warning)
        XCTAssertNil(recovered.isDegraded)
        XCTAssertNil(store.providerErrors["openrouter"])
    }

    func testNegativeBalanceReachesWidgetAndLocalLimitsAPI() async throws {
        let suite = "OpenRouterCreditsPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = FakeHTTPClient(response: creditsResponse(#"{"total_credits":100,"total_usage":103}"#))
        let provider = makeProvider(http: http)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider],
                                   cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "openrouter.balance" })
        let widget = store.data(for: descriptor)

        XCTAssertTrue(widget.hasData)
        XCTAssertEqual(widget.selectedValues.first?.number, -3)
        XCTAssertEqual(widget.valueText, "-$3.00")
        XCTAssertTrue(widget.unboundedDetail.contains("-$3.00"))

        let snapshot = try XCTUnwrap(store.localSnapshots["openrouter"])
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["openrouter"], knownIDs: ["openrouter"],
                                        snapshots: ["openrouter": snapshot], limitDescriptors: ["openrouter": provider.widgetDescriptors])
        let body = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let exported = try XCTUnwrap(providers["openrouter"] as? [String: Any])
        let resources = try XCTUnwrap(exported["resources"] as? [String: Any])
        let balance = try XCTUnwrap(resources["balance"] as? [String: Any])
        XCTAssertEqual(balance["available"] as? Double, -3)
        XCTAssertEqual(balance["unit"] as? String, "usd")
    }

    private func makeProvider(http: any HTTPClient) -> OpenRouterProvider {
        OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OPENROUTER_API_KEY": "fixture"])),
            usageClient: OpenRouterUsageClient(http: http)
        )
    }
}

private func creditsResponse(_ data: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"data\":\(data)}".utf8))
}
