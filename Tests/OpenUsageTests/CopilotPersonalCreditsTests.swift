import XCTest
@testable import OpenUsage

final class CopilotPersonalCreditsMapperTests: XCTestCase {
    func testOrganizationSeatReportsPersonalCreditCountWithoutAnInventedLimit() throws {
        let mapped = try CopilotUsageMapper.map(body: personalBody(credits: 2111))

        XCTAssertEqual(mapped.plan, "Business")
        XCTAssertTrue(mapped.isOrgManagedSeat)
        XCTAssertEqual(mapped.lines, [.values(label: "Credits", values: [MetricValue(number: 2111, kind: .count)])])
    }

    func testMissingNullAndZeroPersonalCreditsKeepExpectedNoDataState() throws {
        for value in [nil, NSNull(), 0, "0"] as [Any?] {
            let mapped = try CopilotUsageMapper.map(body: personalBody(credits: value))
            XCTAssertTrue(mapped.lines.isEmpty)
            XCTAssertTrue(mapped.isOrgManagedSeat)
            XCTAssertFalse(mapped.hasInvalidPersonalCredits)
        }
    }

    func testPersonalCreditsPreserveFractionsAndNumericStrings() throws {
        for value in [2111.125, "2111.125"] as [Any] {
            let mapped = try CopilotUsageMapper.map(body: personalBody(credits: value))
            XCTAssertEqual(mapped.lines, [.values(label: "Credits", values: [MetricValue(number: 2111.125, kind: .count)])])
            XCTAssertFalse(mapped.hasInvalidPersonalCredits)
        }
    }

    func testMalformedPersonalCreditsAreNotReportedAsZeroOrAuthenticationFailure() throws {
        for value in [-1, true, false, "invalid", "NaN", "Infinity", Double.infinity] as [Any] {
            let mapped = try CopilotUsageMapper.map(body: personalBody(credits: value))
            XCTAssertTrue(mapped.lines.isEmpty)
            XCTAssertTrue(mapped.isOrgManagedSeat)
            XCTAssertTrue(mapped.hasInvalidPersonalCredits)
        }
    }

    func testRealPercentQuotaTakesPrecedenceOverPersonalCount() throws {
        var body = personalBody(credits: 2111)
        body["quota_snapshots"] = ["premium_interactions": ["entitlement": 100, "remaining": 75, "credits_used": 2111]]
        let mapped = try CopilotUsageMapper.map(body: body)
        XCTAssertEqual(mapped.lines, [.progress(label: "Credits", used: 25, limit: 100, format: .percent,
                                                periodDurationMs: CopilotUsageMapper.periodMs)])
        XCTAssertFalse(mapped.isOrgManagedSeat)
        XCTAssertFalse(mapped.hasInvalidPersonalCredits)
    }

    func testChatAndLegacyQuotasTakePrecedenceOverPersonalFallback() throws {
        for legacy in [false, true] {
            var body = personalBody(credits: 2111)
            if legacy {
                body["limited_user_quotas"] = ["chat": 75]
                body["monthly_quotas"] = ["chat": 100]
            } else {
                var snapshots = try XCTUnwrap(body["quota_snapshots"] as? [String: Any])
                snapshots["chat"] = ["entitlement": 100, "remaining": 75]
                body["quota_snapshots"] = snapshots
            }
            let mapped = try CopilotUsageMapper.map(body: body)
            XCTAssertEqual(mapped.lines.map(\.label), ["Chat"])
            XCTAssertFalse(mapped.isOrgManagedSeat)
        }
    }

    func testPersonalCountWithoutRootOrgMarkerDoesNotHideUnavailableQuota() {
        var body = personalBody(credits: 2111)
        body.removeValue(forKey: "token_based_billing")
        XCTAssertThrowsError(try CopilotUsageMapper.map(body: body)) { error in
            XCTAssertEqual(error as? CopilotUsageError, .quotaUnavailable)
        }
    }
}

@MainActor
final class CopilotPersonalCreditsProviderTests: XCTestCase {
    func testPersonalAndOrganizationCountsRemainSeparateInProviderAPIAndWidget() async throws {
        let defaults = freshDefaults()
        let provider = makeProvider(
            usageHTTP: FakeHTTPClient(response: try ok(personalBody(credits: 2111.125))),
            orgHTTP: organizationHTTP(), defaults: defaults
        )
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)

        _ = await store.refresh(providerID: "copilot", force: true)
        let snapshot = try XCTUnwrap(store.localSnapshots["copilot"])
        XCTAssertEqual(snapshot.lines.map(\.label), ["Credits", "Org Credits", "Org Spend"])
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "fixture-org")
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.authenticationIssue)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.liveQuotaObservedAt)

        let exported = try resources(snapshot, provider: provider)
        let personal = try XCTUnwrap(exported["premiumCredits"] as? [String: Any])
        let organization = try XCTUnwrap(exported["orgCredits"] as? [String: Any])
        XCTAssertEqual(personal["used"] as? Double, 2111.125)
        XCTAssertEqual(personal["unit"] as? String, "credits")
        XCTAssertEqual(organization["used"] as? Double, 9000)
        for key in ["limit", "remaining", "utilization", "resetsAt", "windowSeconds"] {
            XCTAssertNil(personal[key], key)
        }
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "copilot.premium" })
        let widget = store.data(for: descriptor)
        XCTAssertTrue(widget.hasData)
        XCTAssertFalse(widget.isBounded)
        XCTAssertFalse(widget.isQuotaMeter)
        XCTAssertFalse(widget.valueText.contains("%"))
        XCTAssertFalse(widget.menuBarValue.contains("%"))
        XCTAssertEqual(widget.selectedValues.first?.number, 2111.125)
        XCTAssertNil(descriptor.softLimitWindow)
    }

    func testPersonalCountSurvivesMissingOrganizationPermissions() async throws {
        for blockOrgList in [true, false] {
            let provider = makeProvider(
                usageHTTP: FakeHTTPClient(response: try ok(personalBody(credits: 2111))),
                orgHTTP: organizationHTTP(status: 403, blockOrgList: blockOrgList), defaults: freshDefaults()
            )
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.lines, [.values(label: "Credits", values: [MetricValue(number: 2111, kind: .count)])])
            XCTAssertNil(snapshot.warning)
            XCTAssertNil(snapshot.isDegraded)
            XCTAssertNil(snapshot.authenticationIssue)
            XCTAssertNil(snapshot.errorCategory)
        }
    }

    func testPersonalCountAndRememberedOrganizationSurviveTransientOrgFailures() async throws {
        for transportFailure in [false, true] {
            let defaults = freshDefaults()
            defaults.set("fixture-org", forKey: CopilotProvider.billingOrgDefaultsKey)
            let orgHTTP = RoutingHTTPClient { _ in
                if transportFailure { throw CopilotUsageError.connectionFailed }
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            let provider = makeProvider(usageHTTP: FakeHTTPClient(response: try ok(personalBody(credits: 2111))),
                                        orgHTTP: orgHTTP, defaults: defaults)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.lines.map(\.label), ["Credits"])
            XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "fixture-org")
            XCTAssertEqual(orgHTTP.requests.count, 1)
            XCTAssertNil(snapshot.errorCategory)
        }
    }

    func testMalformedPersonalCountKeepsOrgDataAndRecoversWithoutDuplicateOutcomes() async throws {
        let defaults = freshDefaults()
        let usageHTTP = FakeHTTPClient(response: try ok(personalBody(credits: "invalid")))
        let provider = makeProvider(usageHTTP: usageHTTP, orgHTTP: organizationHTTP(), defaults: defaults)
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        var outcomes: [WidgetDataStore.RefreshOutcome] = []
        var degraded: [Bool] = []
        store.onRefreshOutcome = { _, outcome, _, _, partial in
            outcomes.append(outcome)
            degraded.append(partial)
        }

        _ = await store.refresh(providerID: "copilot", force: true)
        let partial = try XCTUnwrap(store.localSnapshots["copilot"])
        XCTAssertEqual(partial.lines.map(\.label), ["Org Credits", "Org Spend"])
        XCTAssertNotNil(partial.warning)
        XCTAssertEqual(partial.isDegraded, true)
        XCTAssertNil(partial.errorCategory)
        XCTAssertNil(partial.authenticationIssue)
        XCTAssertNil(try resources(partial, provider: provider)["premiumCredits"])

        usageHTTP.response = try ok(personalBody(credits: 2111))
        _ = await store.refresh(providerID: "copilot", force: true)
        let recovered = try XCTUnwrap(store.localSnapshots["copilot"])
        XCTAssertEqual(recovered.lines.map(\.label), ["Credits", "Org Credits", "Org Spend"])
        XCTAssertNil(recovered.warning)
        XCTAssertNil(recovered.isDegraded)

        usageHTTP.response = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        _ = await store.refresh(providerID: "copilot", force: true)
        XCTAssertEqual(store.localSnapshots["copilot"], recovered)
        XCTAssertEqual(cache.snapshot(providerID: "copilot"), recovered)
        XCTAssertNotNil(store.providerErrors["copilot"])
        XCTAssertEqual(outcomes, [.refreshed, .refreshed, .failed])
        XCTAssertEqual(degraded, [true, false, false])
    }

    func testMalformedPersonalCountStillReportsPartialPlanWhenOrgIsUnavailable() async throws {
        let provider = makeProvider(usageHTTP: FakeHTTPClient(response: try ok(personalBody(credits: -1))),
                                    orgHTTP: organizationHTTP(status: 403), defaults: freshDefaults())
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.authenticationIssue)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testPaidPercentKeepsExistingAPIUnitAndDoesNotQueryOrganizations() async throws {
        var body = personalBody(credits: 2111)
        body["quota_snapshots"] = ["premium_interactions": ["entitlement": 100, "remaining": 75, "credits_used": 2111]]
        let orgHTTP = RoutingHTTPClient { _ in
            XCTFail("paid quota must not query organizations")
            return HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }
        let provider = makeProvider(usageHTTP: FakeHTTPClient(response: try ok(body)), orgHTTP: orgHTTP, defaults: freshDefaults())
        let snapshot = await provider.refresh()
        let resource = try XCTUnwrap(try resources(snapshot, provider: provider)["premiumCredits"] as? [String: Any])
        XCTAssertEqual(resource["unit"] as? String, "percent")
        XCTAssertEqual(resource["used"] as? Double, 25)
        XCTAssertEqual(resource["limit"] as? Double, 100)
        XCTAssertEqual(resource["remaining"] as? Double, 75)
        XCTAssertTrue(orgHTTP.requests.isEmpty)
    }

    private func makeProvider(usageHTTP: any HTTPClient, orgHTTP: any HTTPClient, defaults: UserDefaults) -> CopilotProvider {
        CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{"github.com":{"oauth_token":"fixture-token"}}"#
            ]), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: usageHTTP),
            orgBillingClient: CopilotOrgBillingClient(http: orgHTTP), defaults: defaults
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "CopilotPersonalCreditsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func resources(_ snapshot: ProviderSnapshot, provider: CopilotProvider) throws -> [String: Any] {
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["copilot"], knownIDs: ["copilot"], snapshots: ["copilot": snapshot],
                                        limitDescriptors: ["copilot": provider.widgetDescriptors])
        let body = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let copilot = try XCTUnwrap(providers["copilot"] as? [String: Any])
        XCTAssertEqual((root["errors"] as? [Any])?.count, 0)
        return try XCTUnwrap(copilot["resources"] as? [String: Any])
    }
}

private func personalBody(credits: Any?) -> [String: Any] {
    var premium: [String: Any] = [
        "entitlement": 0, "remaining": 0, "percent_remaining": 0,
        "overage_permitted": true, "overage_count": 0, "token_based_billing": true
    ]
    premium["credits_used"] = credits
    return [
        "copilot_plan": "business", "token_based_billing": true,
        "quota_snapshots": ["premium_interactions": premium,
                            "chat": ["entitlement": 0, "remaining": 0],
                            "completions": ["entitlement": 0, "remaining": 0]]
    ]
}

private func ok(_ body: Any) throws -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
}

private func organizationHTTP(status: Int = 200, blockOrgList: Bool = false) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        if request.url.path == "/user/orgs", !blockOrgList {
            return try ok([["login": "fixture-org"]])
        }
        if status != 200 { return HTTPResponse(statusCode: status, headers: [:], body: Data()) }
        return try ok(["usageItems": [["product": "Copilot", "unitType": "ai-credits", "grossQuantity": 9000, "netAmount": 12]]])
    }
}
