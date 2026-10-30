import XCTest
@testable import OpenUsage

@MainActor
final class AntigravityCloudCodeTests: XCTestCase {
    private let productionHost = "cloudcode-pa.googleapis.com"
    private let dailyHost = "daily-cloudcode-pa.googleapis.com"
    private let completeSummary = """
    {"groups":[{"buckets":[
      {"bucketId":"gemini-5h","remainingFraction":0.75},
      {"bucketId":"gemini-weekly","remainingFraction":0.9},
      {"bucketId":"3p-5h","remainingFraction":0.4},
      {"bucketId":"3p-weekly","remainingFraction":0.6}
    ]}]}
    """
    private let claudeSummary = """
    {"groups":[{"buckets":[
      {"bucketId":"3p-5h","remainingFraction":0.4},
      {"bucketId":"3p-weekly","remainingFraction":0.6}
    ]}]}
    """
    private let geminiSummary = """
    {"groups":[{"buckets":[
      {"bucketId":"gemini-5h","remainingFraction":0.75},
      {"bucketId":"gemini-weekly","remainingFraction":0.9}
    ]}]}
    """

    func testPartialProductionAndDailySummariesMergeAllFourBuckets() async {
        let routing = makeRouting(production: response(claudeSummary), daily: response(geminiSummary))

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map(used), [25, 10, 60, 40])
        XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
        assertNoLegacyRequests(routing)
    }

    func testCompleteProductionSummarySkipsDaily() async {
        let routing = makeRouting(production: response(completeSummary), daily: response(#"{"groups":[]}"#))

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(used), [25, 10, 60, 40])
        XCTAssertEqual(summaryHosts(routing), [productionHost])
        assertNoLegacyRequests(routing)
    }

    func testDuplicateBucketsKeepFirstUsableProductionValuesAndResetTime() async {
        let production = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"2026-10-20T09:00:00Z"},
          {"bucketId":"3p-5h","remainingFraction":0.4}
        ]}]}
        """
        let daily = """
        {"response":{"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.1,"resetTime":"2026-10-20T12:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":0.9},
          {"bucketId":"3p-5h","remainingFraction":0.2},
          {"bucketId":"3p-weekly","remainingFraction":0.6}
        ]}]}}
        """
        let routing = makeRouting(production: response(production), daily: response(daily))

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertEqual(snapshot.lines.map(used), [25, 10, 60, 40])
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = snapshot.lines.first else {
            return XCTFail("Expected a Gemini session progress line")
        }
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-10-20T09:00:00Z"))
        XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
    }

    func testMissingFractionInProductionCanBeFilledFromDaily() async {
        let production = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","resetTime":"2026-10-20T09:00:00Z"},
          {"bucketId":"gemini-weekly","remainingFraction":"unknown"},
          {"bucketId":"3p-5h","remainingFraction":0.4},
          {"bucketId":"3p-weekly","remainingFraction":0.6}
        ]}]}
        """
        let routing = makeRouting(production: response(production), daily: response(geminiSummary))

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(used), [25, 10, 60, 40])
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = snapshot.lines.first else {
            return XCTFail("Expected a Gemini session progress line")
        }
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-10-20T09:00:00Z"))
        XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
        assertNoLegacyRequests(routing)
    }

    func testMissingProductionResetTimeCanBeFilledFromDaily() throws {
        let production = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75}]}]}"#
        let daily = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.1,"resetTime":"2026-10-20T09:00:00Z"}]}]}"#

        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries([production, daily].map { Data($0.utf8) }))

        XCTAssertEqual(lines.map(used), [25])
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = lines.first else {
            return XCTFail("Expected a Gemini session progress line")
        }
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-10-20T09:00:00Z"))
    }

    func testMalformedProductionFractionKeepsResetTimeWhenDailySuppliesFraction() throws {
        let production = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":"unknown","resetTime":"2026-10-20T09:00:00Z"}]}]}"#
        let daily = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75}]}]}"#

        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries([production, daily].map { Data($0.utf8) }))

        XCTAssertEqual(lines.map(used), [25])
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = lines.first else {
            return XCTFail("Expected a Gemini session progress line")
        }
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-10-20T09:00:00Z"))
    }

    func testSummaryMergeKeepsFirstValidResetTime() throws {
        let production = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.75,"resetTime":"invalid"}]}]}"#
        let daily = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","resetTime":"2026-10-20T09:00:00Z"},
          {"bucketId":"gemini-5h","remainingFraction":0.1,"resetTime":"2026-10-20T12:00:00Z"}
        ]}]}
        """

        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries([production, daily].map { Data($0.utf8) }))

        XCTAssertEqual(lines.map(used), [25])
        guard case .progress(_, _, _, _, let resetsAt, _, _)? = lines.first else {
            return XCTFail("Expected a Gemini session progress line")
        }
        XCTAssertEqual(resetsAt, OpenUsageISO8601.date(from: "2026-10-20T09:00:00Z"))
    }

    func testResetTimesWithoutAnyValidFractionDoNotCreateLine() throws {
        let production = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":"unknown","resetTime":"2026-10-20T09:00:00Z"}]}]}"#
        let daily = #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","resetTime":"2026-10-20T12:00:00Z"}]}]}"#

        let lines = try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummaries([production, daily].map { Data($0.utf8) }))

        XCTAssertTrue(lines.isEmpty)
    }

    func testProductionFailureStillUsesValidDailySummary() async {
        let failures = [
            response("", status: 401), response("", status: 403),
            response("", status: 500), response("not json")
        ]
        for failure in failures {
            let routing = makeRouting(production: failure, daily: response(geminiSummary))

            let snapshot = await makeProvider(routing).refresh()

            XCTAssertNil(snapshot.errorCategory, "Production status: \(failure.statusCode)")
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
            XCTAssertEqual(snapshot.lines.map(used), [25, 10])
            XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
            assertNoLegacyRequests(routing)
        }
    }

    func testDailyFailurePreservesValidPartialProductionSummary() async {
        let failures = [
            response("", status: 401), response("", status: 403),
            response("", status: 500), response("not json")
        ]
        for failure in failures {
            let routing = makeRouting(production: response(claudeSummary), daily: failure)

            let snapshot = await makeProvider(routing).refresh()

            XCTAssertNil(snapshot.errorCategory, "Daily status: \(failure.statusCode)")
            XCTAssertEqual(snapshot.lines.map(\.label), ["Claude", "Claude Weekly"])
            XCTAssertEqual(snapshot.lines.map(used), [60, 40])
            XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
            assertNoLegacyRequests(routing)
        }
    }

    func testBothHostsRejectTokenReportsAuthExpired() async {
        let routing = makeRouting(production: response("", status: 401), daily: response("", status: 403))

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertEqual(snapshot.errorCategory, .authExpired)
        XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
        assertNoLegacyRequests(routing)
    }

    func testMalformedSummaryCannotHideOtherHostsAuthFailure() async {
        for status in [401, 403] {
            for authFirst in [true, false] {
                let malformed = response("not json")
                let rejected = response("", status: status)
                let routing = makeRouting(
                    production: authFirst ? rejected : malformed,
                    daily: authFirst ? malformed : rejected
                )

                let snapshot = await makeProvider(routing).refresh()

                XCTAssertEqual(snapshot.errorCategory, .authExpired)
                XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
                assertNoLegacyRequests(routing)
            }
        }
    }

    func testAuthoritativeEmptySummarySurvivesDailyAuthFailureWithoutLegacyFallback() async {
        let routing = makeRouting(production: response(#"{"groups":[]}"#), daily: response("", status: 401))

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
        assertNoLegacyRequests(routing)
    }

    func testEmptySummariesDoNotFallBackToLegacy() async {
        let empty = response(#"{"groups":[]}"#)
        let routing = makeRouting(production: empty, daily: empty)

        let snapshot = await makeProvider(routing).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.lines.isEmpty)
        XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
        assertNoLegacyRequests(routing)
    }

    func testLoadCodeAssistIncludesClientMetadataAndSupportedUserAgent() async throws {
        let routing = makeRouting(production: response(completeSummary), daily: response(completeSummary))

        _ = await makeProvider(routing).refresh()

        let request = try XCTUnwrap(routing.requests.first {
            $0.url.path == AntigravityUsageClient.loadCodeAssistPath
        })
        let body = try XCTUnwrap(request.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let metadata = try XCTUnwrap(payload["metadata"] as? [String: String])
        XCTAssertEqual(metadata["ideType"], "ANTIGRAVITY")
        XCTAssertEqual(metadata["pluginType"], "GEMINI")
        XCTAssertEqual(metadata["platform"], "PLATFORM_UNSPECIFIED")
        let userAgent = try XCTUnwrap(request.headers["User-Agent"])
        XCTAssertTrue([
            "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=arm64)",
            "antigravity/2.24.0 (aidev_client; os_type=darwin; arch=amd64)"
        ].contains(userAgent), "Unsupported user agent: \(userAgent)")
    }

    func testPaidTierIDTakesPriorityOverMisleadingDisplayName() async {
        for (id, expected) in [("g1-pro-tier", "Pro"), ("g1-ultra-tier", "Ultra"), ("g1-ultra-lite-tier", "Ultra Lite")] {
            let plan = """
            {"paidTier":{"id":"\(id)","name":"Generic Paid Plan"},"currentTier":{"name":"Free"}}
            """
            let routing = makeRouting(production: response(completeSummary), daily: response(completeSummary), plan: plan)

            let snapshot = await makeProvider(routing).refresh()

            XCTAssertEqual(snapshot.plan, expected)
        }
    }

    func testUnknownOrBlankPaidTierIDFallsBackToDisplayName() async {
        for id in ["", "  ", "unknown-tier"] {
            let plan = """
            {"paidTier":{"id":"\(id)","name":"Google AI Pro"},"currentTier":{"id":"free-tier","name":"Free"}}
            """
            let routing = makeRouting(production: response(completeSummary), daily: response(completeSummary), plan: plan)

            let snapshot = await makeProvider(routing).refresh()

            XCTAssertEqual(snapshot.plan, "Pro")
        }
    }

    func testCurrentTierNameIsUsedWhenPaidTierIsMissingOrBlank() async {
        let plans = [
            #"{"currentTier":{"name":"Google AI Pro"}}"#,
            #"{"paidTier":{"name":""},"currentTier":{"name":"Google AI Pro"}}"#,
            #"{"paidTier":{"name":"  "},"currentTier":{"name":"Google AI Pro"}}"#
        ]
        for plan in plans {
            let routing = makeRouting(production: response(completeSummary), daily: response(completeSummary), plan: plan)

            let snapshot = await makeProvider(routing).refresh()

            XCTAssertEqual(snapshot.plan, "Pro")
        }
    }

    func testUnavailablePlanDoesNotDiscardQuotaOrRefreshOAuthToken() async {
        let summary = response(completeSummary)
        let planResponses = [
            response("", status: 401),
            response("", status: 503),
            response("not json"),
            response(#"{"allowedTiers":[{"id":"g1-ultra-tier","name":"Google AI Ultra"}]}"#)
        ]
        for planResponse in planResponses {
            let routing = RoutingHTTPClient { request in
                if request.url.path == AntigravityUsageClient.quotaSummaryPath { return summary }
                if request.url.path == AntigravityUsageClient.loadCodeAssistPath { return planResponse }
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }

            let snapshot = await makeProvider(routing, withRefreshToken: true).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.plan)
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
            XCTAssertEqual(snapshot.lines.map(used), [25, 10, 60, 40])
            XCTAssertTrue(routing.requests.contains { $0.url.path == AntigravityUsageClient.loadCodeAssistPath })
            XCTAssertFalse(routing.requests.contains { $0.url.host == "oauth2.googleapis.com" })
            assertNoLegacyRequests(routing)
        }
    }

    func testLoadCodeAssistUsesDailyBeforeProduction() async {
        let summary = response(completeSummary)
        let plan = response(#"{"paidTier":{"name":"Google AI Pro"}}"#)
        for status in [401, 403] {
            let rejected = response("", status: status)
            let routing = RoutingHTTPClient { request in
                if request.url.path == AntigravityUsageClient.quotaSummaryPath { return summary }
                if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                    return request.url.host == "daily-cloudcode-pa.googleapis.com" ? plan : rejected
                }
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }

            let snapshot = await makeProvider(routing, withRefreshToken: true).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.plan, "Pro")
            XCTAssertEqual(snapshot.lines.map(used), [25, 10, 60, 40])
            XCTAssertEqual(summaryHosts(routing), [productionHost])
            XCTAssertEqual(routing.requests.filter {
                $0.url.path == AntigravityUsageClient.loadCodeAssistPath
            }.compactMap(\.url.host), [dailyHost])
            XCTAssertFalse(routing.requests.contains { $0.url.host == "oauth2.googleapis.com" })
        }
    }

    func testLegacyModelsUseDailyBeforeProduction() async {
        let models = response("""
        {"models":{"gemini":{"displayName":"Gemini 3.1 Pro","quotaInfo":{"remainingFraction":0.75}}}}
        """)
        let plan = response(#"{"paidTier":{"name":"Google AI Pro"}}"#)
        for status in [401, 403] {
            let rejected = response("", status: status)
            let routing = RoutingHTTPClient { request in
                if request.url.path == AntigravityUsageClient.fetchModelsPath {
                    return request.url.host == "daily-cloudcode-pa.googleapis.com" ? models : rejected
                }
                if request.url.path == AntigravityUsageClient.loadCodeAssistPath { return plan }
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }

            let snapshot = await makeProvider(routing, withRefreshToken: true).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.plan, "Pro")
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session"])
            XCTAssertEqual(snapshot.lines.map(used), [25])
            XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
            XCTAssertEqual(routing.requests.filter {
                $0.url.path == AntigravityUsageClient.fetchModelsPath
            }.compactMap(\.url.host), [dailyHost])
            XCTAssertFalse(routing.requests.contains { $0.url.host == "oauth2.googleapis.com" })
        }
    }

    func testQuotaFallbackUsesDailyBeforeProduction() async {
        let quota = response(#"{"buckets":[{"modelId":"gemini-3-pro-preview","remainingFraction":0.5}]}"#)
        let plan = response(#"{"paidTier":{"name":"Google AI Pro"},"cloudaicompanionProject":"test-project"}"#)
        for status in [401, 403] {
            let rejected = response("", status: status)
            let routing = RoutingHTTPClient { request in
                if request.url.path == AntigravityUsageClient.retrieveQuotaPath {
                    return request.url.host == "daily-cloudcode-pa.googleapis.com" ? quota : rejected
                }
                if request.url.path == AntigravityUsageClient.loadCodeAssistPath { return plan }
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }

            let snapshot = await makeProvider(routing, withRefreshToken: true).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.plan, "Pro")
            XCTAssertEqual(snapshot.lines.map(\.label), ["Session"])
            XCTAssertEqual(snapshot.lines.map(used), [50])
            XCTAssertEqual(summaryHosts(routing), [productionHost, dailyHost])
            XCTAssertEqual(routing.requests.filter {
                $0.url.path == AntigravityUsageClient.retrieveQuotaPath
            }.compactMap(\.url.host), [dailyHost])
            XCTAssertFalse(routing.requests.contains { $0.url.host == "oauth2.googleapis.com" })
        }
    }

    private func makeProvider(_ routing: RoutingHTTPClient, withRefreshToken: Bool = false) -> AntigravityProvider {
        let token = withRefreshToken
            ? #"{"token":{"access_token":"ya29.test","refresh_token":"1//test","expiry":"2099-01-01T00:00:00Z"}}"#
            : #"{"token":{"access_token":"ya29.test","expiry":"2099-01-01T00:00:00Z"}}"#
        let wrapped = "go-keyring-base64:" + Data(token.utf8).base64EncodedString()
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(wrapped), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: NoProcessRunner()),
            usageScan: { _, _ in nil },
            pricing: { .empty }
        )
    }

    private func makeRouting(
        production: HTTPResponse,
        daily: HTTPResponse,
        plan: String = #"{"paidTier":{"name":"Google AI Pro"}}"#
    ) -> RoutingHTTPClient {
        let planResponse = response(plan)
        return RoutingHTTPClient { request in
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                return request.url.host == "cloudcode-pa.googleapis.com" ? production : daily
            }
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return planResponse
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
    }

    private func response(_ body: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
    }

    private func used(_ line: MetricLine) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = line else { return nil }
        return used
    }

    private func summaryHosts(_ routing: RoutingHTTPClient) -> [String] {
        routing.requests.filter { $0.url.path == AntigravityUsageClient.quotaSummaryPath }.compactMap(\.url.host)
    }

    private func assertNoLegacyRequests(
        _ routing: RoutingHTTPClient,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(routing.requests.contains {
            $0.url.path == AntigravityUsageClient.fetchModelsPath ||
                $0.url.path == AntigravityUsageClient.retrieveQuotaPath
        }, file: file, line: line)
    }
}

private struct NoProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
