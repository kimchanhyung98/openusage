import XCTest
@testable import OpenUsage

@MainActor
final class GrokSessionCostCompletenessTests: XCTestCase {
    private let instant = OpenUsageISO8601.date(from: "2026-11-01T12:00:00Z")!

    func testCostOnlyMismatchKeepsTokensAndOmitsCostAtEveryLevel() async throws {
        for level in ["model", "turn", "session"] {
            for scenario in ["missing", "zero", "negative", "different"] {
                var row = metrics()
                switch scenario {
                case "missing": row.removeValue(forKey: "costUsdTicks")
                case "zero": row["costUsdTicks"] = 0
                case "negative": row["costUsdTicks"] = -1
                default: row["costUsdTicks"] = 3_000_000_000
                }
                let object = snapshot(
                    model: level == "model" ? row : metrics(),
                    turn: level == "turn" ? row : metrics(),
                    session: level == "session" ? row : metrics()
                )
                let root = try fixture(object)
                let parsed = try parse(root)
                let context = "\(level):\(scenario)"
                XCTAssertTrue(parsed.usable, context)
                XCTAssertEqual(parsed.records.count, 1, context)
                XCTAssertEqual(parsed.records.first?.totalTokens, 120, context)
                XCTAssertEqual(parsed.records.first?.tokens, TokenBreakdown(input: 100, output: 20), context)
                XCTAssertNil(parsed.records.first?.recordedCostUSD, context)
                XCTAssertEqual(parsed.records.first?.costOrigin, .reported, context)
                XCTAssertTrue(parsed.records.first?.issues.isEmpty == true, context)

                let result = await scanner(root).scan(now: instant, pricing: TestPricing.bundled)
                let scan = try XCTUnwrap(result)
                XCTAssertEqual(scan.series.daily.first?.totalTokens, 120, context)
                XCTAssertNil(scan.series.daily.first?.costUSD, context)
                XCTAssertEqual(scan.rejectedMetadataRows, 0, context)
            }
        }
    }

    func testTurnCostMismatchKeepsOtherTurnsReportedCost() async throws {
        var missingCost = metrics()
        missingCost.removeValue(forKey: "costUsdTicks")
        var first = metrics()
        first["turnNumber"] = 1
        first["endedAt"] = "2026-10-31T10:00:00Z"
        first["modelUsage"] = ["grok-build": missingCost]
        var second = metrics()
        second["turnNumber"] = 2
        second["endedAt"] = "2026-11-01T10:00:00Z"
        second["modelUsage"] = ["grok-build": metrics()]
        var session = metrics(input: 200, output: 40)
        session["modelCalls"] = 2
        session["costUsdTicks"] = 5_000_000_000
        let root = try fixture(["sessionId": "main", "session": session, "turns": [first, second]])

        let parsed = try parse(root)

        XCTAssertTrue(parsed.usable)
        XCTAssertEqual(parsed.records.map(\.totalTokens), [120, 120])
        XCTAssertNil(parsed.records[0].recordedCostUSD)
        XCTAssertEqual(parsed.records[1].recordedCostUSD, 0.25)
        let scanResult = await scanner(root).scan(now: instant, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(scanResult)
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [120, 120])
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD), [0.25])
        XCTAssertEqual(scan.rejectedMetadataRows, 0)
    }

    func testTokenCounterMismatchStillRejectsTheSnapshot() throws {
        for level in ["model", "turn", "session"] {
            let changed = metrics(input: 90)
            let root = try fixture(snapshot(
                model: level == "model" ? changed : metrics(),
                turn: level == "turn" ? changed : metrics(),
                session: level == "session" ? changed : metrics()
            ))

            let parsed = try parse(root)

            XCTAssertFalse(parsed.usable, level)
            XCTAssertEqual(parsed.records.count, 1, level)
            XCTAssertTrue(parsed.records.first?.issues.contains(.invalidMetadata) == true, level)
            XCTAssertEqual(parsed.records.first?.totalTokens, 0, level)
        }
    }

    func testKnownModelIncompleteUsageKeepsTokensWithoutCardWarning() async throws {
        var row = metrics()
        row["usageIsIncomplete"] = true
        let root = try fixture(snapshot(model: row, turn: row, session: row))
        let now = instant
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: FakeFiles([
                GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","expires_at":"2026-12-01T00:00:00Z"}}"#
            ]), environment: FakeEnvironment(), now: { now }),
            usageClient: GrokUsageClient(httpClient: RoutingHTTPClient { request in
                if request.url == GrokUsageClient.creditsConfigURL {
                    return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }),
            logUsageScanner: scanner(root),
            sharedUsage: UsageCollectionCoordinator(collectors: []),
            now: { now }, pricing: { TestPricing.bundled }
        )

        let result = await provider.refresh()

        XCTAssertNil(result.errorCategory)
        XCTAssertNotNil(result.usageHistory)
        XCTAssertNil(result.warning)
        XCTAssertNil(result.warningPresentation)
        let scanResult = await scanner(root).scan(now: instant, pricing: TestPricing.bundled)
        let scan = try XCTUnwrap(scanResult)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 120)
        XCTAssertNil(scan.series.daily.first?.costUSD)
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
    }

    private func metrics(input: Int = 100, output: Int = 20) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output, "totalTokens": input + output,
         "modelCalls": 1, "costUsdTicks": 2_500_000_000]
    }

    private func snapshot(model: [String: Any], turn: [String: Any], session: [String: Any]) -> [String: Any] {
        var turn = turn
        turn["turnNumber"] = 1
        turn["endedAt"] = "2026-11-01T10:00:00Z"
        turn["modelUsage"] = ["grok-build": model]
        return ["sessionId": "main", "session": session, "turns": [turn]]
    }

    private func fixture(_ object: [String: Any]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("sessions/workspace/main")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try JSONSerialization.data(withJSONObject: object).write(to: session.appendingPathComponent("usage.json"))
        try JSONSerialization.data(withJSONObject: ["info": ["id": "main"], "session_kind": "worktree"])
            .write(to: session.appendingPathComponent("summary.json"))
        return root
    }

    private func parse(_ root: URL) throws -> GrokSessionUsageScanner.Parsed {
        let path = root.appendingPathComponent("sessions/workspace/main/usage.json").path
        return GrokSessionUsageScanner.parse(try String(contentsOfFile: path, encoding: .utf8), path: path)
    }

    private func scanner(_ root: URL) -> GrokLogUsageScanner {
        GrokLogUsageScanner(
            files: LocalTextFileAccessor(), environment: FakeEnvironment(["GROK_HOME": root.path]),
            homeDirectory: { root }
        )
    }
}
