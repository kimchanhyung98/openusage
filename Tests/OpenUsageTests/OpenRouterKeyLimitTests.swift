import XCTest
@testable import OpenUsage

final class OpenRouterKeyLimitMapperTests: XCTestCase {
    func testKeyLimitUsesCurrentWindowRemainingInsteadOfLifetimeSpend() throws {
        for lifetimeUsage in [12.0, 4.0] {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: [
                "usage": lifetimeUsage, "limit": 5, "limit_remaining": 3
            ])
            guard case .progress(_, let used, let limit, let format, _, _, _) = mapped.lines.first else {
                return XCTFail("expected current key limit")
            }
            XCTAssertEqual(used, 2)
            XCTAssertEqual(limit, 5)
            XCTAssertEqual(format, .dollars)
        }
    }

    func testResetPolicyAndBYOKDoNotChangeRemainingBasedCalculation() {
        for reset in ["daily", "weekly", "monthly", "never"] {
            for includesBYOK in [true, false] {
                let mapped = OpenRouterUsageMapper.keyMetrics(from: [
                    "limit": "5", "limit_remaining": "3", "limit_reset": reset,
                    "include_byok_in_limit": includesBYOK, "usage": 99,
                    "usage_daily": 0.5, "usage_weekly": 2, "usage_monthly": 8, "byok_usage": 50
                ])
                XCTAssertEqual(mapped.lines.last, .progress(label: "Key Limit", used: 2, limit: 5, format: .dollars))
                XCTAssertEqual(mapped.lines.map(\.label), ["Today", "This Week", "This Month", "Key Limit"])
                XCTAssertFalse(mapped.hasInvalidKeyLimit)
            }
        }
    }

    func testFiniteRemainingNormalizationPreservesZeroAndExhaustion() {
        for (remaining, used) in [(0.0, 5.0), (5, 0), (-3, 5), (8, 0), (Double.greatestFiniteMagnitude, 0)] {
            let mapped = OpenRouterUsageMapper.keyMetrics(from: ["limit": 5, "limit_remaining": remaining])
            XCTAssertEqual(mapped.lines, [.progress(label: "Key Limit", used: used, limit: 5, format: .dollars)])
            XCTAssertFalse(mapped.hasInvalidKeyLimit)
        }
    }

    func testInvalidRemainingOmitsOnlyKeyLimitWithoutInventingUsage() {
        let invalidValues: [Any?] = [nil, NSNull(), true, false, "bad", "NaN", "Infinity", Double.infinity]
        for remaining in invalidValues {
            var data: [String: Any] = ["limit": 5, "usage": 99, "usage_daily": 0, "is_free_tier": false]
            data["limit_remaining"] = remaining
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            XCTAssertEqual(mapped.plan, "Pay as you go")
            XCTAssertEqual(mapped.lines, [.values(label: "Today", values: [MetricValue(number: 0, kind: .dollars)])])
            XCTAssertTrue(mapped.hasInvalidKeyLimit)
        }
    }

    func testMissingOrUnlimitedCapDoesNotRequireRemaining() {
        for limit in [nil, NSNull(), 0] as [Any?] {
            var data: [String: Any] = ["usage_daily": 1]
            data["limit"] = limit
            let mapped = OpenRouterUsageMapper.keyMetrics(from: data)
            XCTAssertEqual(mapped.lines.map(\.label), ["Today"])
            XCTAssertFalse(mapped.hasInvalidKeyLimit)
        }
    }
}

@MainActor
final class OpenRouterKeyLimitProviderTests: XCTestCase {
    func testPartialRefreshReplacesStaleLimitRecoversAndReportsOneOutcomePerRefresh() async throws {
        let suite = "OpenRouterKeyLimitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let http = FakeHTTPClient(response: response(#"{"total_credits":100,"total_usage":40,"limit":5,"limit_remaining":3,"usage":12}"#))
        let provider = makeProvider(http: http)
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        var outcomes: [WidgetDataStore.RefreshOutcome] = []
        var degraded: [Bool] = []
        store.onRefreshOutcome = { _, outcome, _, _, partial in
            outcomes.append(outcome)
            degraded.append(partial)
        }

        _ = await store.refresh(providerID: "openrouter", force: true)
        let initial = try XCTUnwrap(store.localSnapshots["openrouter"])
        let initialResource = try XCTUnwrap(try resources(initial, provider: provider)["keyLimit"] as? [String: Any])
        XCTAssertEqual(initialResource["used"] as? Double, 2)
        XCTAssertEqual(initialResource["remaining"] as? Double, 3)
        XCTAssertEqual(initialResource["utilization"] as? Double, 0.4)
        XCTAssertEqual(initialResource["unit"] as? String, "usd")

        http.response = response(#"{"total_credits":100,"total_usage":41,"limit":5,"usage":13,"usage_daily":1}"#)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let partial = try XCTUnwrap(store.localSnapshots["openrouter"])
        XCTAssertEqual(partial.lines.map(\.label), ["Credits", "Balance", "Today"])
        XCTAssertNotNil(partial.warning)
        XCTAssertEqual(partial.isDegraded, true)
        XCTAssertNil(partial.authenticationIssue)
        XCTAssertNil(partial.errorCategory)
        XCTAssertNil(partial.liveQuotaObservedAt)
        XCTAssertNil(try resources(partial, provider: provider)["keyLimit"])

        http.response = response(#"{"limit":5}"#)
        _ = await store.refresh(providerID: "openrouter", force: true)
        XCTAssertEqual(store.localSnapshots["openrouter"], partial)
        XCTAssertEqual(cache.snapshot(providerID: "openrouter"), partial)
        XCTAssertNotNil(store.providerErrors["openrouter"])

        http.response = response(#"{"limit":5,"limit_remaining":5}"#)
        _ = await store.refresh(providerID: "openrouter", force: true)
        let recovered = try XCTUnwrap(store.localSnapshots["openrouter"])
        XCTAssertNil(recovered.warning)
        XCTAssertNil(recovered.isDegraded)
        XCTAssertNil(store.providerErrors["openrouter"])
        XCTAssertEqual(recovered.lines, [.progress(label: "Key Limit", used: 0, limit: 5, format: .dollars)])
        XCTAssertEqual(outcomes, [.refreshed, .refreshed, .failed, .refreshed])
        XCTAssertEqual(degraded, [false, true, false, false])
    }

    func testInvalidKeyLimitWithoutOtherRowsIsDecodingFailureDespiteOptionalCreditsFailure() async {
        for status in [403, 503] {
            let provider = makeProvider(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: status, headers: [:], body: Data())
                }
                return response(#"{"limit":5,"limit_remaining":null}"#)
            })
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, .decoding)
            XCTAssertNil(snapshot.authenticationIssue)
        }
    }

    func testInvalidKeyLimitKeepsKeySpendWhenCreditsAreForbidden() async {
        let provider = makeProvider(http: RoutingHTTPClient { request in
            if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                return HTTPResponse(statusCode: 403, headers: [:], body: Data())
            }
            return response(#"{"limit":5,"usage_daily":0}"#)
        })
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.lines.map(\.label), ["Today"])
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.authenticationIssue)
    }

    private func makeProvider(http: any HTTPClient) -> OpenRouterProvider {
        OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OPENROUTER_API_KEY": "fixture"])),
            usageClient: OpenRouterUsageClient(http: http)
        )
    }

    private func resources(_ snapshot: ProviderSnapshot, provider: OpenRouterProvider) throws -> [String: Any] {
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["openrouter"], knownIDs: ["openrouter"],
                                        snapshots: ["openrouter": snapshot], limitDescriptors: ["openrouter": provider.widgetDescriptors])
        let body = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let provider = try XCTUnwrap(providers["openrouter"] as? [String: Any])
        XCTAssertEqual((root["errors"] as? [Any])?.count, 0)
        return try XCTUnwrap(provider["resources"] as? [String: Any])
    }
}

private func response(_ data: String) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data("{\"data\":\(data)}".utf8))
}
