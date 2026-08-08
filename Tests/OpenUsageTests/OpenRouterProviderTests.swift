import XCTest
@testable import OpenUsage

final class OpenRouterAuthStoreTests: XCTestCase {
    func testPrefersConfigFileOverEnvironment() {
        // config file 우선 — key 교체가 stale env 값에 가려지지 않도록
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "sk-or-file")
    }

    func testFallsBackToEnvironmentWhenNoConfigFile() {
        let store = OpenRouterAuthStore(
            files: FakeFiles(),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "sk-or-env")
    }

    func testReadsKeyFromJSONConfigFile() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{ "api_key": "sk-or-json" }"#]),
            environment: FakeEnvironment()
        )

        let auth = store.loadAPIKey()

        XCTAssertEqual(auth?.apiKey, "sk-or-json")
    }

    func testReadsPlainTextKeyFile() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[1]: "  sk-or-plain\n"]),
            environment: FakeEnvironment()
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-plain")
    }

    func testReturnsNilWhenNoKeyAnywhere() {
        let store = OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNil(store.loadAPIKey())
    }

    func testIgnoresBlankConfigAndUsesEnvironment() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: "   "]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-env")
    }

    // MARK: - In-app save / delete / status (Customize → OpenRouter → API Key)

    func testSaveAPIKeyWritesTrimmedJSONConfigFile() throws {
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.saveAPIKey("  sk-or-new  ")

        // sorted-keys JSON + trimmed key — auth store가 round-trip하는 바이트 그대로
        XCTAssertEqual(files.files[OpenRouterAuthStore.configPaths[0]], #"{"apiKey":"sk-or-new"}"#)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-new")
    }

    func testSaveAPIKeyRejectsEmptyKey() {
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.saveAPIKey("   ")) { error in
            XCTAssertEqual(error as? OpenRouterAuthError, .missingKey)
        }
        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
    }

    func testSavedKeyOverridesEnvironment() throws {
        // 저장된 config file이 env var보다 우선 — status는 overrideActive
        let files = FakeFiles()
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]))

        try store.saveAPIKey("sk-or-saved")

        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-saved")
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testKeyStatusReportsAllFourStates() {
        let envKey = ["OPENROUTER_API_KEY": "sk-or-env"]
        let file = [OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]

        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()).keyStatus(), .notSet)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(envKey)).keyStatus(), .fromEnvironment)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment()).keyStatus(), .saved)
        XCTAssertEqual(OpenRouterAuthStore(files: FakeFiles(file), environment: FakeEnvironment(envKey)).keyStatus(), .overrideActive)
    }

    func testKeyStatusOverrideActiveEvenWhenKeysMatch() {
        // 값이 같아도 saved + env 조합은 override — config 우선
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-same"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-same"])
        )
        XCTAssertEqual(store.keyStatus(), .overrideActive)
    }

    func testCurrentAPIKeyReturnsEffectiveKey() {
        let store = OpenRouterAuthStore(
            files: FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#]),
            environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])
        )
        XCTAssertEqual(store.currentAPIKey(), "sk-or-file")
    }

    func testDeleteAPIKeyFallsBackToEnvironment() throws {
        let files = FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"]))

        XCTAssertEqual(store.keyStatus(), .overrideActive)
        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
        XCTAssertEqual(store.keyStatus(), .fromEnvironment)
        XCTAssertEqual(store.loadAPIKey()?.apiKey, "sk-or-env")
    }

    func testDeleteAPIKeyBecomesNotSetWhenNoEnvKey() throws {
        let files = FakeFiles([OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-file"}"#])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
        XCTAssertEqual(store.keyStatus(), .notSet)
        XCTAssertNil(store.loadAPIKey())
    }

    func testDeleteAPIKeyIsNoOpWhenFileMissing() throws {
        // 없는 key 삭제는 목표 상태 달성 — error 아님
        let store = OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment())
        XCTAssertNoThrow(try store.deleteAPIKey())
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testDeleteAPIKeyClearsAllConfigPaths() throws {
        // alternate config path의 key도 함께 삭제 — 남으면 clear가 동작하지 않는 것처럼 보임
        let files = FakeFiles([
            OpenRouterAuthStore.configPaths[0]: #"{"apiKey":"sk-or-primary"}"#,
            OpenRouterAuthStore.configPaths[1]: "sk-or-alt"
        ])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[0]])
        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[1]])
        XCTAssertEqual(store.keyStatus(), .notSet)
    }

    func testDeleteAPIKeyClearsAlternatePathOnly() throws {
        let files = FakeFiles([OpenRouterAuthStore.configPaths[1]: "sk-or-alt"])
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertEqual(store.keyStatus(), .saved)
        try store.deleteAPIKey()

        XCTAssertNil(files.files[OpenRouterAuthStore.configPaths[1]])
        XCTAssertEqual(store.keyStatus(), .notSet)
    }
}

final class OpenRouterUsageMapperTests: XCTestCase {
    func testCreditsLinesGiveMeterAndBalance() throws {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": 277.47, "total_usage": 178.20])

        let credits = try XCTUnwrap(progress(lines, "Credits"))
        XCTAssertEqual(credits.used, 178.20, accuracy: 0.001)
        XCTAssertEqual(credits.limit, 277.47, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(dollars(lines, "Balance")), 99.27, accuracy: 0.001)
    }

    func testCreditsLinesEmptyWithoutUsableTotal() {
        XCTAssertTrue(OpenRouterUsageMapper.creditsLines(from: ["foo": "bar"]).isEmpty)
    }

    func testNoCreditsMeterWhenNothingPurchased() {
        let lines = OpenRouterUsageMapper.creditsLines(from: ["total_credits": 0, "total_usage": 0])

        XCTAssertNil(progress(lines, "Credits"))
        // Balance는 실측 0으로 표시 — "No data" 아님
        XCTAssertEqual(dollars(lines, "Balance"), 0)
    }

    func testKeyMetricsGivePlanPeriodSpendAndCap() throws {
        let mapped = OpenRouterUsageMapper.keyMetrics(from: [
            "is_free_tier": false,
            "usage_daily": 0,
            "usage_weekly": 1.25,
            "usage_monthly": 4.5,
            "usage": 2,
            "limit": 5
        ])

        XCTAssertEqual(mapped.plan, "Pay as you go")
        // 실측 0 표시 — "No data"로 축약 금지
        XCTAssertEqual(dollars(mapped.lines, "Today"), 0)
        XCTAssertEqual(dollars(mapped.lines, "This Week"), 1.25)
        XCTAssertEqual(dollars(mapped.lines, "This Month"), 4.5)
        let keyLimit = try XCTUnwrap(progress(mapped.lines, "Key Limit"))
        XCTAssertEqual(keyLimit.used, 2)
        XCTAssertEqual(keyLimit.limit, 5)
    }

    func testKeyMetricsOmitCapWhenUnset() {
        let mapped = OpenRouterUsageMapper.keyMetrics(from: ["is_free_tier": true, "limit": NSNull()])

        XCTAssertEqual(mapped.plan, "Free tier")
        XCTAssertNil(progress(mapped.lines, "Key Limit"))
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }

    private func dollars(_ lines: [MetricLine], _ label: String) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return values.first(where: { $0.kind == .dollars })?.number
    }
}

@MainActor
final class OpenRouterProviderTests: XCTestCase {
    func testRefreshMapsBothEndpoints() async throws {
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    XCTAssertEqual(request.headers["Authorization"], "Bearer sk-or-test")
                    return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
                }
                return jsonResponse(["data": ["is_free_tier": false, "usage_daily": 0.5]])
            }),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pay as you go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Credits"))
        XCTAssertNotNil(snapshot.line(label: "Balance"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testRefreshSurvivesKeyEndpointFailure() async {
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return jsonResponse(["data": ["total_credits": 100, "total_usage": 40]])
                }
                throw OpenRouterUsageError.connectionFailed
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Balance"))
    }

    func testRefreshShowsKeyDataWhenCreditsForbidden() async {
        // `/credits` 403이어도 `/key` 성공 시 error 대신 spend row 표시
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                return jsonResponse(["data": ["is_free_tier": false, "usage_daily": 0.5, "usage_weekly": 2]])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertFalse(snapshot.lines.contains { $0.isError })
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Balance"))
    }

    func testRefreshWithoutKeyReportsNotLoggedIn() async {
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment()),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("should not hit the network without a key")
                return jsonResponse([:])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.first?.label, "Error")
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshOnAuthFailureReportsInvalidKey() async {
        // 두 endpoint 모두 key 거부 — hard auth failure
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-bad"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 401, headers: [:], body: Data("{}".utf8))
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
    }

    func testRefreshDoesNotReportInvalidKeyWhenOnlyCreditsForbidden() async {
        // `/credits`만 403(해당 key 유형에 gated), `/key`는 200 — key는 유효하므로 invalid key 판정 금지
        let provider = OpenRouterProvider(
            authStore: makeAuthStore(key: "sk-or-test"),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { request in
                if request.url.absoluteString == OpenRouterUsageClient.creditsURL {
                    return HTTPResponse(statusCode: 403, headers: [:], body: Data("{}".utf8))
                }
                // `/key` 200이지만 usable field 없음 → metric line 없음
                return jsonResponse(["data": [:]])
            })
        )

        let snapshot = await provider.refresh()

        XCTAssertNotEqual(snapshot.errorCategory, .authInvalid)
    }

    func testProviderAPIKeyManagingDelegatesToAuthStore() throws {
        let files = FakeFiles()
        let provider = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: files, environment: FakeEnvironment(["OPENROUTER_API_KEY": "sk-or-env"])),
            usageClient: OpenRouterUsageClient(http: RoutingHTTPClient { _ in jsonResponse([:]) })
        )

        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        XCTAssertEqual(provider.currentAPIKey(), "sk-or-env")

        try provider.saveAPIKey("sk-or-saved")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "sk-or-saved")

        try provider.deleteAPIKey()
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
    }

    private func makeAuthStore(key: String) -> OpenRouterAuthStore {
        OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(["OPENROUTER_API_KEY": key]))
    }
}

private func jsonResponse(_ object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    return HTTPResponse(statusCode: 200, headers: [:], body: body)
}
