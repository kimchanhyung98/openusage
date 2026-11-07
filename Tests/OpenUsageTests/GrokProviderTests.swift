import XCTest
@testable import OpenUsage

@MainActor
final class GrokProviderTests: XCTestCase {
    func testRefreshFormEncodesReservedCharactersInRequestBody() async throws {
        let httpClient = RecordingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data())
        }
        let client = GrokUsageClient(httpClient: httpClient)

        _ = try await client.refreshToken("refresh token&=+/?%", clientID: "client id&=+/?%")

        let request = try XCTUnwrap(httpClient.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "grant_type=refresh_token&client_id=client%20id%26%3D%2B%2F%3F%25" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
    }

    func testRefreshesExpiredTokenPersistsAuthAndFetchesUsage() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "expired-token",
                "refresh_token": "refresh-token",
                "oidc_client_id": "client-id",
                "expires_at": "2026-01-01T00:00:00.000Z",
                "custom_field": "keep-me"
              }
            }
            """
        ])
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.refreshURL {
                XCTAssertEqual(request.method, "POST")
                XCTAssertEqual(String(data: request.body ?? Data(), encoding: .utf8), "grant_type=refresh_token&client_id=client-id&refresh_token=refresh-token")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.creditsConfigURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.settingsURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer new-token")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, environment: FakeEnvironment(), now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            sharedUsage: .init(collectors: []),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")

        let saved = GrokAuthStore.parseAuth(files.files[GrokAuthStore.authPath] ?? "")
        let entry = saved?["https://auth.x.ai::client"]
        XCTAssertEqual(entry?.key, "new-token")
        XCTAssertEqual(entry?.refreshToken, "new-refresh")
        XCTAssertEqual(entry?.expiresAt, "2026-02-02T01:00:00.000Z")
        let savedObject = GrokAuthStore.parseJSONObject(files.files[GrokAuthStore.authPath] ?? "")
        let rawEntry = savedObject?["https://auth.x.ai::client"] as? [String: Any]
        XCTAssertEqual(rawEntry?["custom_field"] as? String, "keep-me")
    }

    func testRetriesCreditsOnceAfterAuthError() async {
        let now = OpenUsageISO8601.date(from: "2026-02-02T00:00:00.000Z")!
        let files = FakeFiles([
            GrokAuthStore.authPath: """
            {
              "https://auth.x.ai::client": {
                "key": "old-token",
                "refresh_token": "refresh-token",
                "expires_at": "2026-06-01T00:00:00.000Z"
              }
            }
            """
        ])
        var creditsCalls = 0
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                creditsCalls += 1
                if creditsCalls == 1 {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            if request.url == GrokUsageClient.refreshURL {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            if request.url == GrokUsageClient.settingsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files, environment: FakeEnvironment(), now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: noLogScanner(),
            sharedUsage: .init(collectors: []),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "SuperGrok Heavy")
        let creditsAuths = httpClient.requests
            .filter { $0.url == GrokUsageClient.creditsConfigURL }
            .map { $0.headers["Authorization"] }
        XCTAssertEqual(creditsAuths, ["Bearer old-token", "Bearer new-token"])
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
    }

    func testWeeklyMeterAndPayAsYouGoComeFromCreditsConfig() async {
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                // Grok CLI와 동일한 plain GET + 표준 auth header
                XCTAssertEqual(request.method, "GET")
                XCTAssertNil(request.body)
                XCTAssertEqual(request.headers["Authorization"], "Bearer token")
                XCTAssertEqual(request.headers["X-XAI-Token-Auth"], GrokUsageClient.tokenAuthHeader)
                XCTAssertEqual(request.headers["User-Agent"], "OpenUsage")
                return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.limit, 100)
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.resetsAt?.timeIntervalSince1970 ?? 0,
                       GrokCreditsFixtures.capturedPeriodEnd.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertNil(snapshot.warning)
    }

    func testCreditsFetchFailureFailsTheProvider() async {
        // credits config가 유일한 remote meter — 실패는 partial degrade가 아니라 provider error
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
    }

    func testMalformedBodyInsideHTTP200FailsTheProvider() async {
        // HTTP 200에 미지의 body shape은 schema drift — 조용한 빈 dashboard 대신 loud fail
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"config":{}}"#.utf8))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
    }

    func testNonWeeklyPeriodShowsNoWeeklyLineAndNoWarning() async {
        // monthly-period(미이전) 계정은 정상 상태 — Weekly tile은 경고 없이 "No data", badge는 유지
        let httpClient = RecordingHTTPClient { request in
            if request.url == GrokUsageClient.creditsConfigURL {
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: GrokCreditsFixtures.responseBody(periodType: "USAGE_PERIOD_TYPE_MONTHLY"))
            }
            return Self.defaultRoutes(request)
        }
        let provider = makeProvider(httpClient: httpClient)

        let snapshot = await provider.refresh()

        XCTAssertNil(progress(snapshot.lines, "Weekly limit"))
        XCTAssertEqual(badge(snapshot.lines, "Pay as you go")?.text, "Disabled")
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testRefreshAppendsLocalSpendTilesFromLog() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        // 오늘 grok-build 장문 입력 1M × $2 = $2, 어제 composer-2.5-fast 출력 1M × $15 = $15.
        let log = """
        {"ts":"2026-06-18T09:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-18T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-17T09:00:00.000Z","pid":2,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-17T10:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": log]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        // 기존 credit line 유지 + local log에서 spend tile 3종 추가
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertEqual(values(snapshot.lines, "Today"),
                       [MetricValue(number: 2.0, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(snapshot.lines, "Yesterday"),
                       [MetricValue(number: 15.0, kind: .dollars, estimated: true), MetricValue(number: 1_000_000, kind: .count, label: "tokens")])
        XCTAssertEqual(values(snapshot.lines, "Last 30 Days"),
                       [MetricValue(number: 17.0, kind: .dollars, estimated: true), MetricValue(number: 2_000_000, kind: .count, label: "tokens")])
    }

    func testUnreadableNativeLogKeepsSharedUsageWithWarningAndPreservesHistoryOnTotalFailure() async throws {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        let files = GrokNativeReadFixture()
        let shared = GrokSharedReadFixture(tokens: 50, now: now)
        let scanner = GrokLogUsageScanner(
            files: files, environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/fixture/grok-read") }
        )
        let provider = makeProvider(
            httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner,
            now: now, sharedUsage: UsageCollectionCoordinator(collectors: [shared])
        )
        let suite = "GrokProviderTests.nativeRead." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, now: { now }
        )
        _ = await store.refresh(providerID: "grok", force: true)
        XCTAssertEqual(store.localSnapshots["grok"]?.usageHistory?.series.daily.first?.totalTokens, 170)

        files.setUnreadable(true)
        await shared.setTokens(60)
        _ = await store.refresh(providerID: "grok", force: true)
        let partial = try XCTUnwrap(store.localSnapshots["grok"])
        XCTAssertEqual(partial.usageHistory?.series.daily.first?.totalTokens, 60)
        XCTAssertEqual(partial.warning, "Some local usage files could not be read. Usage history may be incomplete.")
        XCTAssertNil(partial.errorCategory)

        await shared.setTokens(nil)
        _ = await store.refresh(providerID: "grok", force: true)
        let retained = try XCTUnwrap(store.localSnapshots["grok"])
        XCTAssertEqual(retained.usageHistory, partial.usageHistory)
        XCTAssertEqual(retained.warning, "Some local usage files could not be read. Usage history may be incomplete.")
    }

    func testPeriodWithoutUsageLeavesTileUnbacked() async {
        // "Today 0" 회귀 방지 — 오늘 usage 없으면 "$0.00 · 0 tokens" 조작 대신 backing line 없는 "No data"
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        // fixture: 06-17에만 inference row, 06-18(today)은 없음
        let log = """
        {"ts":"2026-06-17T09:00:00.000Z","pid":2,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-17T10:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": log]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        // 오늘 usage 없음 → Today line 없음, Yesterday·30일 합계는 유지
        XCTAssertNil(values(snapshot.lines, "Today"))
        XCTAssertNotNil(values(snapshot.lines, "Yesterday"))
        XCTAssertNotNil(values(snapshot.lines, "Last 30 Days"))
    }

    func testRefreshAppendsUsageTrendFromLog() async {
        let now = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!
        // 픽스처: 06-18 입력 1M, 06-17 출력 1M
        let log = """
        {"ts":"2026-06-18T09:00:00.000Z","pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-18T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-17T09:00:00.000Z","pid":2,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-17T10:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":0,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": log]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner, now: now)

        let snapshot = await provider.refresh()

        guard case .chart(_, let points, let note) = snapshot.lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(note, "From your Grok usage files and logs (estimated)")
        XCTAssertEqual(points.count, 31)
        XCTAssertEqual(points.last?.value, 1_000_000, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 1_000_000, "yesterday's tokens land on the second-to-last bar")
    }

    func testInvalidOnlyLocalHistoryPreservesHistoryAndWeeklyMeterWithoutCardWarning() async {
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": """
            {"pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
            {"ts":"2026-06-18T10:00:00Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1e300}}
            """]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner)

        let snapshot = await provider.refresh()

        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.usageHistory, "A successful quota refresh must not publish an empty history for invalid logs")
        XCTAssertNil(values(snapshot.lines, "Today"))
    }

    func testRefreshWithoutLogAppendsNoUsageTrend() async {
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes))

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Usage Trend" }), "no log means no trend chart")
    }

    func testUnattributedAndInvalidSessionsPreserveHistoryWithoutCardWarnings() async {
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": """
            {"pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
            {"pid":1,"msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast"}}
            {"ts":"2026-06-18T10:00:00Z","pid":1,"sid":"unknown-child","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000}}
            {"ts":"2026-06-18T11:00:00Z","pid":1,"sid":"unknown-child","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":-1}}
            """]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let provider = makeProvider(httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner)
        let snapshot = await provider.refresh()

        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(values(snapshot.lines, "Today"))
    }

    func testUnscopedAmbiguousUsageDoesNotPublishEmptyHistoryOrCardWarning() async {
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(["/home/test/.grok/logs/unified.jsonl": """
            {"pid":1,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
            {"pid":1,"msg":"subagent model resolved","ctx":{"child_model":"grok-composer-2.5-fast"}}
            {"ts":"2026-06-18T10:00:00Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000}}
            """]),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/test") }
        )
        let snapshot = await makeProvider(
            httpClient: RecordingHTTPClient(handler: Self.defaultRoutes), scanner: scanner
        ).refresh()
        XCTAssertEqual(progress(snapshot.lines, "Weekly limit")?.used, 99)
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.errorCategory)
    }

    /// happy-path 기본 route — 캡처된 weekly credits config + plan 이름
    private static func defaultRoutes(_ request: HTTPRequest) -> HTTPResponse {
        if request.url == GrokUsageClient.creditsConfigURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
        }
        if request.url == GrokUsageClient.settingsURL {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"subscription_tier_display":"SuperGrok Heavy"}"#.utf8))
        }
        return HTTPResponse(statusCode: 404, headers: [:], body: Data())
    }

    private func makeProvider(
        httpClient: RecordingHTTPClient,
        scanner: GrokLogUsageScanner? = nil,
        now: Date = OpenUsageISO8601.date(from: "2026-06-18T12:00:00.000Z")!,
        sharedUsage: UsageCollectionCoordinator = .init(collectors: [])
    ) -> GrokProvider {
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","refresh_token":"refresh","expires_at":"2026-07-01T00:00:00.000Z"}}"#
        ])
        return GrokProvider(
            authStore: GrokAuthStore(files: files, environment: FakeEnvironment(), now: { now }),
            usageClient: GrokUsageClient(httpClient: httpClient),
            logUsageScanner: scanner ?? noLogScanner(),
            sharedUsage: sharedUsage,
            now: { now },
            pricing: { TestPricing.bundled }
        )
    }

    private func noLogScanner() -> GrokLogUsageScanner {
        GrokLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(), homeDirectory: { URL(fileURLWithPath: "/home/none") })
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

private actor GrokSharedReadFixture: UsageCollecting {
    private var tokens: Int?
    private let now: Date

    init(tokens: Int?, now: Date) { self.tokens = tokens; self.now = now }
    func setTokens(_ value: Int?) { tokens = value }
    func collect(since: Date) async -> UsageCollection? {
        guard let tokens else { return UsageCollection(records: []) }
        return UsageCollection(records: [UsageRecord(
            sourceID: "pi", formatID: "pi-session", sessionID: "fixture", id: "entry", kind: "message",
            timestamp: now, providerID: "grok", model: "grok-build", tokens: TokenBreakdown(input: tokens),
            totalTokens: tokens, recordedCostUSD: 0.5
        )])
    }
}

private final class GrokNativeReadFixture: TextFileAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var unreadable = false
    func setUnreadable(_ value: Bool) { lock.withLock { unreadable = value } }
    func exists(_ path: String) -> Bool { path.hasSuffix("/logs/unified.jsonl") }
    func readText(_ path: String) throws -> String {
        if lock.withLock({ unreadable }) { throw CocoaError(.fileReadNoPermission) }
        return """
        {"ts":"2026-06-18T09:00:00Z","pid":1,"sid":"s","msg":"backend_search: model switch","ctx":{"model_id":"grok-build","api_backend":"Responses"}}
        {"ts":"2026-06-18T09:01:00Z","pid":1,"sid":"s","msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100,"completion_tokens":20}}
        """
    }
    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

@MainActor
final class GrokWidgetDataStoreTests: XCTestCase {
    func testResolvesBadgeSnapshotIntoWidgetText() async {
        let provider = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor(
            id: "grok.payAsYouGo",
            providerID: provider.id,
            metricLabel: "Pay as you go",
            sample: WidgetData(title: "Pay as you go", icon: provider.icon, kind: .count, used: 0, limit: nil)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.badge(label: "Pay as you go", text: "$25.00 cap", colorHex: "#22c55e")]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]), providers: [runtime])

        await store.refreshAll()

        XCTAssertEqual(store.data(for: descriptor).valueText, "$25.00 cap")
    }
}

private final class RecordingHTTPClient: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    private let handler: (HTTPRequest) throws -> HTTPResponse

    init(handler: @escaping (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double, resetsAt: Date?)? {
    guard case .progress(_, let used, let limit, _, let resetsAt, _, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (used, limit, resetsAt)
}

private func badge(_ lines: [MetricLine], _ label: String) -> (text: String, colorHex: String?)? {
    guard case .badge(_, let text, let colorHex, _) = lines.first(where: { $0.label == label }) else {
        return nil
    }
    return (text, colorHex)
}
