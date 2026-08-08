import XCTest
@testable import OpenUsage

final class CopilotAuthStoreTests: XCTestCase {
    func testReadsEditorAppsJSON() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: """
                { "github.com:Iv1.abc123": { "user": "octocat", "oauth_token": "gho_editor" } }
                """
            ]),
            keychain: FakeKeychain()
        )

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_editor")
    }

    func testReadsGhHostsOAuthToken() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                github.com:
                    git_protocol: https
                    user: octocat
                    oauth_token: gho_ghconfig
                """
            ]),
            keychain: FakeKeychain()
        )

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_ghconfig")
    }

    func testDecodesGoKeyringWrappedGhKeychainToken() {
        let wrapped = "go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString()
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain(wrapped))

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_keychain")
    }

    func testEditorConfigWinsOverKeychain() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_keychain".utf8).base64EncodedString())
        )

        XCTAssertEqual(store.loadToken()?.value, "gho_editor")
    }

    func testReturnsNilWhenNoCredentials() {
        let store = CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain())
        XCTAssertNil(store.loadToken())
    }

    func testEditorConfigIgnoresNonGithubDotComHost() {
        // Enterprise 전용 editor config는 api.github.com token을 내지 않음 — gh keychain으로 fall through
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_enterprise" } }"#
            ]),
            keychain: FakeKeychain("go-keyring-base64:" + Data("gho_dotcom".utf8).base64EncodedString())
        )

        let token = store.loadToken()

        XCTAssertEqual(token?.value, "gho_dotcom")
    }

    func testEditorConfigPicksGithubDotComAmongHosts() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.editorAppsPath: #"{ "ghe.corp.example:Iv1.x": { "oauth_token": "gho_ent" }, "github.com:Iv1.y": { "oauth_token": "gho_dotcom" } }"#
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(store.loadToken()?.value, "gho_dotcom")
    }

    func testYamlValueIgnoresNestedUsersMap() {
        let hosts = """
        github.com:
            users:
                octocat:
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testYamlValueScopesToGithubDotComHost() {
        // GitHub Enterprise 블록이 github.com보다 앞 — github.com token 우선
        let hosts = """
        ghe.corp.example:
            oauth_token: gho_enterprise
            user: ent
        github.com:
            oauth_token: gho_dotcom
            user: octocat
        """
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "oauth_token"), "gho_dotcom")
        XCTAssertEqual(CopilotAuthStore.yamlValue(hosts, key: "user"), "octocat")
    }

    func testGhConfigPrefersGithubDotComTokenOverEnterprise() {
        let store = CopilotAuthStore(
            files: FakeFiles([
                CopilotAuthStore.ghHostsPath: """
                ghe.corp.example:
                    oauth_token: gho_enterprise
                github.com:
                    oauth_token: gho_dotcom
                """
            ]),
            keychain: FakeKeychain()
        )

        XCTAssertEqual(store.loadToken()?.value, "gho_dotcom")
    }
}

final class CopilotUsageMapperTests: XCTestCase {
    func testMapsPaidCreditsAndChatAsPercentUsed() throws {
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())

        XCTAssertEqual(mapped.plan, "Pro")
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 5)
        XCTAssertNotNil(progress(mapped.lines, "Credits")?.resetsAt)
        XCTAssertEqual(progress(mapped.lines, "Credits")?.periodDurationMs, CopilotUsageMapper.periodMs)
    }

    func testSuppressesUnlimitedAndSentinelBuckets() throws {
        // 유료 plan의 chat/completions unlimited 보고(명시 플래그 + `-1` sentinel)는 억제 — Credits만 유지
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["unlimited": true, "entitlement": 0, "remaining": 0, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
        XCTAssertEqual(progress(mapped.lines, "Credits")?.used, 59)
    }

    func testEmitsExtraUsageWhenOveragePermitted() throws {
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 36
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), 36)
    }

    func testShowsExtraUsageZeroWhenPermittedButUnused() throws {
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 0
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(mapped.lines, "Extra Usage"), 0)
    }

    func testSuppressesExtraUsageWhenNotPermitted() throws {
        // makePaidBody의 premium에 overage 플래그 없음 → extra usage는 실제 N/A
        let mapped = try CopilotUsageMapper.map(body: makePaidBody())
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
    }

    func testIgnoresLegacyLimitedQuotasWhenSnapshotsPresent() throws {
        // Credits 존재 + chat/completions unlimited(-1)인 유료 응답은 legacy limited_user_quotas 경로로 fallback 금지
        var body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        quota["chat"] = ["entitlement": -1, "remaining": -1, "quota_id": "chat"]
        quota["completions"] = ["entitlement": -1, "remaining": -1, "quota_id": "completions"]
        body["quota_snapshots"] = quota
        body["limited_user_quotas"] = ["chat": 100, "completions": 1000]
        body["monthly_quotas"] = ["chat": 500, "completions": 4000]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNotNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(progress(mapped.lines, "Chat"))
        XCTAssertNil(progress(mapped.lines, "Completions"))
    }

    func testSuppressesZeroEntitlementPlaceholder() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 100, "quota_id": "premium"],
                "chat": ["entitlement": 1000, "remaining": 800, "percent_remaining": 80, "quota_id": "chat"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 20)
    }

    func testMapsLiveFreeAccountSnapshots() throws {
        // 무료 `individual` 계정의 실제 응답 형태 — Credits + Extra Usage 억제, Chat + Completions 렌더
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "access_type_sku": "free_limited_copilot",
            "token_based_billing": true,
            "quota_reset_date": "2099-07-01",
            "quota_snapshots": [
                "chat": ["entitlement": 200, "remaining": 182, "percent_remaining": 91.0, "overage_permitted": false, "token_based_billing": true],
                "completions": ["entitlement": 2000, "remaining": 1989, "percent_remaining": 99.4, "overage_permitted": false, "token_based_billing": true],
                "premium_interactions": ["entitlement": 0, "remaining": 0, "percent_remaining": 0.0, "overage_permitted": false, "token_based_billing": true]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertNil(progress(mapped.lines, "Credits"))
        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used ?? -1, 9, accuracy: 0.0001)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used ?? -1, 0.6, accuracy: 0.0001)
    }

    func testMapsFreeTierLimitedQuotas() throws {
        let body: [String: Any] = [
            "copilot_plan": "individual",
            "limited_user_quotas": ["chat": 250, "completions": 2000],
            "monthly_quotas": ["chat": 500, "completions": 4000],
            "limited_user_reset_date": "2099-02-15"
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Individual")
        XCTAssertEqual(progress(mapped.lines, "Chat")?.used, 50)
        XCTAssertEqual(progress(mapped.lines, "Completions")?.used, 50)
        XCTAssertNotNil(progress(mapped.lines, "Chat")?.resetsAt)
    }

    func testTokenBasedBillingReturnsPlanWithoutMeters() throws {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0, "quota_id": "premium"]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Business")
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)
    }

    func testPlaceholderOveragePermittedDoesNotEmitExtraUsageOrBlockOrgFlag() throws {
        // issue #839 2차 회귀: placeholder의 `overage_permitted: true`는 "Extra Usage: 0" 미렌더 + org-managed 유지
        var body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": [
                "premium_interactions": [
                    "entitlement": 0, "remaining": 0, "unlimited": true,
                    "overage_permitted": true, "overage_count": 0, "token_based_billing": true
                ]
            ]
        ]

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertNil(mapped.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertTrue(mapped.lines.isEmpty)
        XCTAssertTrue(mapped.isOrgManagedSeat)

        // 실제 credit pool 있는 유료 계정은 Extra Usage 행 유지
        body = makePaidBody()
        var quota = body["quota_snapshots"] as! [String: Any]
        var premium = quota["premium_interactions"] as! [String: Any]
        premium["overage_permitted"] = true
        premium["overage_count"] = 12
        quota["premium_interactions"] = premium
        body["quota_snapshots"] = quota

        let paid = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(countValue(paid.lines, "Extra Usage"), 12)
        XCTAssertFalse(paid.isOrgManagedSeat)
    }

    func testThrowsQuotaUnavailableWhenEmpty() {
        XCTAssertThrowsError(try CopilotUsageMapper.map(body: ["copilot_plan": "pro"])) { error in
            XCTAssertEqual(error as? CopilotUsageError, .quotaUnavailable)
        }
    }
}

final class CopilotOrgBillingMapperTests: XCTestCase {
    func testParsesOrgLogins() {
        let body: [[String: Any]] = [["login": "acme", "id": 1], ["login": "globex"], ["id": 3]]
        let response = HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))

        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), ["acme", "globex"])
    }

    func testOrgLoginsEmptyForGarbledBody() {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data("<html>".utf8))
        XCTAssertEqual(CopilotOrgBillingMapper.orgLogins(response), [])
    }

    func testMapsAICreditUsageFromSummary() throws {
        // issue #839 그대로의 형태: Copilot AI-unit 항목 1건, included credits로 전액 커버(netAmount 0)
        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: makeOrgSummaryBody()))

        XCTAssertEqual(orgCount(lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(lines, "Org Spend"), 0)
    }

    func testSumsMultipleCreditItemsAndBilledSpend() throws {
        var body = makeOrgSummaryBody()
        body["usageItems"] = [
            ["product": "Copilot", "sku": "copilot_ai_unit", "unitType": "ai-units", "grossQuantity": 100.5, "netAmount": 1.25],
            ["product": "Copilot", "sku": "Copilot AI Credits", "unitType": "ai-credits", "grossQuantity": 50, "netAmount": 0.5]
        ]

        let lines = try XCTUnwrap(CopilotOrgBillingMapper.usageLines(body: body))

        XCTAssertEqual(orgCount(lines, "Org Credits") ?? -1, 150.5, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(lines, "Org Spend") ?? -1, 1.75, accuracy: 0.0001)
    }

    func testNilWhenNoCopilotCreditItems() {
        // Actions minutes·Copilot seat 요금(비credit 단위)은 org 미터 미생성
        var body = makeOrgSummaryBody()
        body["usageItems"] = [
            ["product": "Actions", "sku": "actions_linux", "unitType": "minutes", "grossQuantity": 120, "netAmount": 0.96],
            ["product": "Copilot", "sku": "copilot_business_seat", "unitType": "user-months", "grossQuantity": 10, "netAmount": 190]
        ]

        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: body))
    }

    func testNilWhenSummaryHasNoUsageItems() {
        XCTAssertNil(CopilotOrgBillingMapper.usageLines(body: ["organization": "acme"]))
    }
}

@MainActor
final class CopilotProviderTests: XCTestCase {
    func testNotLoggedInWhenNoToken() async {
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(files: FakeFiles(), keychain: FakeKeychain()),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(makePaidBody())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testTokenInvalidOn401() async {
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data())))
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
    }

    func testMapsLinesAndSendsTokenHeaderOnSuccess() async throws {
        let http = FakeHTTPClient(response: ok(makePaidBody()))
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.line(label: "Credits")?.label, "Credits")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "token gho_editor")
    }

    func testTokenBasedBillingShowsPlanWithoutError() async {
        let body: [String: Any] = [
            "copilot_plan": "business",
            "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["entitlement": 0, "remaining": 0]]
        ]
        let provider = CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: FakeHTTPClient(response: ok(body)))
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
    }

    func testOrgManagedSeatShowsOrgBillingLines() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertEqual(orgCount(snapshot.lines, "Org Credits") ?? -1, 298.698546, accuracy: 0.0001)
        XCTAssertEqual(orgDollars(snapshot.lines, "Org Spend"), 0)
        // placeholder의 `overage_permitted: true`가 무의미한 Extra Usage 행을 남기지 않아야 함
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Extra Usage" }))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testOrgBillingForbiddenKeepsPlanOnlyCard() async {
        // 일반 org 멤버(owner/billing manager 아님)의 org billing 403은 예상 상태 — plan-only 카드 유지, provider 오류 아님
        let forbidden = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", forbidden)
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Business")
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertNil(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey))
    }

    func testUsesCachedOrgWithoutReprobing() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testEvictsStaleCachedOrgAndReprobes() async {
        // 캐시된 org에 Copilot usage 없음(예: org 변경) — 캐시 삭제 후 discovery 재실행
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/oldorg/settings/billing/usage/summary", HTTPResponse(statusCode: 404, headers: [:], body: Data())),
            ("/user/orgs", okJSON([["login": "acme"]])),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        defaults.set("oldorg", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testDiscoveryKeepsProbingPastAFailingOrg() async {
        // 한 org의 billing endpoint 장애(5xx)가 discovery를 중단시키지 않음 — 다음 org에서 발견·캐시
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/user/orgs", okJSON([["login": "brokenorg"], ["login": "acme"]])),
            ("/orgs/brokenorg/settings/billing/usage/summary", HTTPResponse(statusCode: 503, headers: [:], body: Data())),
            ("/orgs/acme/settings/billing/usage/summary", ok(makeOrgSummaryBody()))
        ])
        let defaults = freshDefaults()
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(orgCount(snapshot.lines, "Org Credits"))
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
    }

    func testTransientBillingFailureKeepsCachedOrg() async {
        // 캐시된 org billing의 5xx는 일시 장애 — 캐시 유지(재discovery 없음), refresh는 plan-only 카드로 degrade
        let http = routedClient([
            ("/copilot_internal/user", ok(makeBusinessPlaceholderBody())),
            ("/orgs/acme/settings/billing/usage/summary", HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        ])
        let defaults = freshDefaults()
        defaults.set("acme", forKey: CopilotProvider.billingOrgDefaultsKey)
        let provider = makeOrgProvider(http: http, defaults: defaults)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertEqual(defaults.string(forKey: CopilotProvider.billingOrgDefaultsKey), "acme")
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("/user/orgs") })
    }

    func testPersonalPaidAccountMakesNoOrgCalls() async {
        let http = routedClient([
            ("/copilot_internal/user", ok(makePaidBody()))
        ])
        let provider = makeOrgProvider(http: http, defaults: freshDefaults())

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
    }

    private func makeOrgProvider(http: RoutingHTTPClient, defaults: UserDefaults) -> CopilotProvider {
        CopilotProvider(
            authStore: editorTokenStore(),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            defaults: defaults
        )
    }

    private func freshDefaults() -> UserDefaults {
        let suiteName = "CopilotProviderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func editorTokenStore() -> CopilotAuthStore {
        CopilotAuthStore(
            files: FakeFiles([CopilotAuthStore.editorAppsPath: #"{ "github.com": { "oauth_token": "gho_editor" } }"#]),
            keychain: FakeKeychain()
        )
    }
}

// MARK: - Helpers

private func routedClient(_ routes: [(substring: String, response: HTTPResponse)]) -> RoutingHTTPClient {
    RoutingHTTPClient { request in
        routes.first(where: { request.url.absoluteString.contains($0.substring) })?.response
            ?? HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }
}

/// issue #839의 org-managed Business seat 응답 형태 — premium bucket의 `overage_permitted: true`가 함정
private func makeBusinessPlaceholderBody() -> [String: Any] {
    func bucket(_ id: String, overagePermitted: Bool) -> [String: Any] {
        [
            "overage_count": 0, "overage_entitlement": 0, "overage_permitted": overagePermitted,
            "percent_remaining": 100.0, "quota_id": id, "quota_remaining": 0.0, "unlimited": true,
            "has_quota": true, "quota_reset_at": 0, "token_based_billing": true,
            "remaining": 0, "entitlement": 0
        ]
    }
    return [
        "copilot_plan": "business",
        "token_based_billing": true,
        "quota_snapshots": [
            "chat": bucket("chat", overagePermitted: false),
            "completions": bucket("completions", overagePermitted: false),
            "premium_interactions": bucket("premium_interactions", overagePermitted: true)
        ]
    ]
}

/// issue #839의 org billing usage summary: Copilot AI-unit 1건, included credits로 전액 커버
private func makeOrgSummaryBody() -> [String: Any] {
    [
        "timePeriod": ["year": 2026, "month": 7],
        "organization": "acme",
        "usageItems": [
            [
                "product": "Copilot",
                "sku": "copilot_ai_unit",
                "unitType": "ai-units",
                "pricePerUnit": 0.01,
                "grossQuantity": 298.698546,
                "grossAmount": 2.98698546,
                "discountQuantity": 298.698546,
                "discountAmount": 2.98698546,
                "netQuantity": 0.0,
                "netAmount": 0.0
            ]
        ]
    ]
}

private func okJSON(_ array: [[String: Any]]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: array))
}

private func orgCount(_ lines: [MetricLine], _ label: String) -> Double? {
    value(lines, label: label, kind: .count)
}

private func orgDollars(_ lines: [MetricLine], _ label: String) -> Double? {
    value(lines, label: label, kind: .dollars)
}

private func value(_ lines: [MetricLine], label: String, kind: MetricKind) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first(where: { $0.kind == kind })?.number
}

private func makePaidBody() -> [String: Any] {
    [
        "copilot_plan": "pro",
        "quota_reset_date": "2099-01-15T00:00:00Z",
        "quota_snapshots": [
            "premium_interactions": ["entitlement": 300, "remaining": 123, "percent_remaining": 41, "quota_id": "premium"],
            "chat": ["entitlement": 1000, "remaining": 950, "percent_remaining": 95, "quota_id": "chat"]
        ]
    ]
}

private func ok(_ body: [String: Any]) -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?, periodDurationMs: Int?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, let periodDurationMs, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt, periodDurationMs)
}

private func countValue(_ lines: [MetricLine], _ label: String) -> Double? {
    guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return values.first?.number
}
