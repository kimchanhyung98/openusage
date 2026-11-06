import XCTest
@testable import OpenUsage

@MainActor
final class GrokSessionUsageTests: XCTestCase {
    private let instant = OpenUsageISO8601.date(from: "2026-11-01T12:00:00Z")!

    func testCompletedTurnWithoutUnifiedLogUsesReportedCostAndTokenSubsets() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")

        let result = try XCTUnwrap(GrokSessionUsageScanner(files: LocalTextFileAccessor()).collect(root: root.appendingPathComponent("sessions")))
        let record = try XCTUnwrap(result.collection.records.first)
        XCTAssertEqual(result.preferredSessionIDs, ["main"])
        XCTAssertEqual(record.costOrigin, .reported)
        XCTAssertEqual(record.granularity, .aggregate)
        XCTAssertEqual(record.tokens, TokenBreakdown(input: 50, cacheWrite5m: 20, cacheRead: 30, output: 20))
        XCTAssertEqual(record.reasoningTokens, 7)
        XCTAssertEqual(record.totalTokens, 120)
        XCTAssertEqual(record.recordedCostUSD, 0.25)

        let scan = try await scan(root)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.25)
        XCTAssertEqual(scan.rejectedMetadataRows, 0)
    }

    func testFutureCompletedTurnWaitsUntilItsEndedAt() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "current")
        try writeSession(root: root, id: "future", endedAt: "2026-11-01T12:01:00Z")
        let usageScanner = scanner(root)

        let before = await usageScanner.scan(now: instant, pricing: TestPricing.bundled)
        XCTAssertEqual(before?.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(before?.series.daily.first?.costUSD, 0.25)

        let after = await usageScanner.scan(now: instant.addingTimeInterval(120), pricing: TestPricing.bundled)
        XCTAssertEqual(after?.series.daily.first?.totalTokens, 240)
        XCTAssertEqual(after?.series.daily.first?.costUSD, 0.5)
    }

    func testIncompleteTurnWarningsUseTheSameInclusiveDateWindowAsHistory() async throws {
        let since = JSONLScanning.sinceDate(daysBack: 2, now: instant)
        let cases = [(since.addingTimeInterval(-1), 0), (since, 1), (instant.addingTimeInterval(-60), 1),
                     (instant, 1), (instant.addingTimeInterval(1), 0)]
        for modelOnly in [false, true] {
            for (date, expected) in cases {
                let root = try fixture()
                try writeSession(root: root, id: "complete")
                try writeIncomplete(root: root, id: "incomplete", date: date, modelOnly: modelOnly)
                let scanned = await scanner(root).scan(daysBack: 2, now: instant, pricing: TestPricing.bundled)
                let result = try XCTUnwrap(scanned)
                XCTAssertEqual(result.rejectedMetadataRows, expected)
                XCTAssertEqual(result.metadataWarning != nil, expected > 0)
                XCTAssertEqual(result.series.daily.reduce(0) { $0 + $1.totalTokens }, 120 * (expected + 1))
                XCTAssertEqual(result.readFailureCount, 0)
            }
        }
    }

    func testOutOfWindowIncompleteTurnsKeepEmptyHistoryButDoNotHideReadFailures() async throws {
        let root = try fixture()
        let since = JSONLScanning.sinceDate(daysBack: 2, now: instant)
        try writeIncomplete(root: root, id: "old", date: since.addingTimeInterval(-1))
        try writeIncomplete(root: root, id: "future", date: instant.addingTimeInterval(1))
        let scanned = await scanner(root).scan(daysBack: 2, now: instant, pricing: TestPricing.bundled)
        let empty = try XCTUnwrap(scanned)
        XCTAssertEqual(empty.usageHistory?.series.daily, [])
        XCTAssertEqual(empty.rejectedMetadataRows, 0)
        XCTAssertNil(empty.metadataWarning)

        let files = GrokUsageReadFailureFiles(failingPath: usageURL(root, id: "old").path)
        let failed = await GrokLogUsageScanner(files: files, environment: FakeEnvironment(["GROK_HOME": root.path]))
            .scan(daysBack: 2, now: instant, pricing: TestPricing.bundled)
        let result = try XCTUnwrap(failed)
        XCTAssertEqual(result.readFailureCount, 1)
        XCTAssertNotNil(result.readWarning)
        XCTAssertEqual(result.rejectedMetadataRows, 0)
        XCTAssertNil(result.usageHistory)
    }

    func testSnapshotReplacesSameSessionLogsButKeepsOtherSessions() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        try write(log(session: "main", input: 200) + log(session: "legacy", input: 60), to: root.appendingPathComponent("logs/unified.jsonl"))

        let result = try await scan(root)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 180)
        // grok-build 기본 입력 $1/1M: 원장 $0.25 + 다른 세션의 입력 60 tokens.
        XCTAssertEqual(try XCTUnwrap(result.series.daily.first?.costUSD), 0.25006, accuracy: 1e-10)
        XCTAssertEqual(result.rejectedMetadataRows, 0)
    }

    func testSymlinkedGrokHomeFindsTheSameSessionSnapshot() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        let link = try fixture().appendingPathComponent("grok-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        let result = try await scan(link)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(result.series.daily.first?.costUSD, 0.25)
    }

    func testSameTurnSnapshotUpdateReplacesPreviousCounters() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        let scanner = scanner(root)
        let first = await scanner.scan(now: instant, pricing: TestPricing.bundled)
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 120)
        try writeSession(root: root, id: "main", input: 150, ticks: 5_000_000_000)

        let second = await scanner.scan(now: instant, pricing: TestPricing.bundled)

        XCTAssertEqual(second?.series.daily.first?.totalTokens, 170)
        XCTAssertEqual(second?.series.daily.first?.costUSD, 0.5)
    }

    func testResumedTurnsDoNotAddSessionCumulativeTotalAgain() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        var object = snapshot(id: "main")
        var second = turn(input: 150, ticks: 5_000_000_000)
        second["turnNumber"] = 2
        object["turns"] = [turn(), second]
        object["session"] = metrics(input: 250, output: 40, read: 60, write: 40, reasoning: 14,
                                    ticks: 7_500_000_000, calls: 2)
        try writeJSON(object, to: usageURL(root, id: "main"))

        let result = try await scan(root)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 290)
        XCTAssertEqual(result.series.daily.first?.costUSD, 0.75)
    }

    func testMissingZeroNegativeAndPartialCostNeverRepricesTurnAggregate() async throws {
        for scenario in ["missing", "zero", "negative", "partial", "incomplete"] {
            let root = try fixture()
            try writeSession(root: root, id: "main")
            var row = metrics()
            switch scenario {
            case "missing": row.removeValue(forKey: "costUsdTicks")
            case "zero": row["costUsdTicks"] = 0
            case "negative": row["costUsdTicks"] = -1
            case "partial": row["costIsPartial"] = true
            default: row["usageIsIncomplete"] = true
            }
            var turn = row
            turn["turnNumber"] = 1
            turn["endedAt"] = "2026-11-01T10:00:00Z"
            turn["modelUsage"] = ["grok-build": row]
            try writeJSON(["sessionId": "main", "session": row, "turns": [turn]], to: usageURL(root, id: "main"))

            let result = try await scan(root)

            XCTAssertEqual(result.series.daily.first?.totalTokens, 120, scenario)
            XCTAssertNil(result.series.daily.first?.costUSD, scenario)
            XCTAssertEqual(result.rejectedMetadataRows > 0, scenario == "incomplete", scenario)
        }
    }

    func testUnpricedModelCanUseProviderReportedCost() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main", model: "grok-unpublished")

        let result = try await scan(root)

        XCTAssertEqual(result.series.daily.first?.costUSD, 0.25)
        XCTAssertTrue(result.unknownModelsByDay.isEmpty)
    }

    func testForkWithUnavailableParentPreservesRawAndFallsBackToLogs() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "fork", parent: "missing-parent", kind: "fork")
        try write(log(session: "fork", input: 60), to: root.appendingPathComponent("logs/unified.jsonl"))

        let raw = try XCTUnwrap(GrokSessionUsageScanner(files: LocalTextFileAccessor()).collect(root: root.appendingPathComponent("sessions")))
        XCTAssertTrue(raw.preferredSessionIDs.isEmpty)
        XCTAssertEqual(raw.collection.records.first?.totalTokens, 120)
        XCTAssertEqual(raw.collection.records.first?.parentSession, "missing-parent")
        XCTAssertTrue(raw.collection.records.first?.issues.contains(.unresolvedMirror) == true)
        let result = try await scan(root)
        XCTAssertEqual(result.series.daily.first?.totalTokens, 60)
        XCTAssertGreaterThan(result.rejectedMetadataRows, 0)
    }

    func testParentAndLateChildSnapshotsAreNotAddedToNativeCalls() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "parent")
        try writeSession(root: root, id: "child", parent: "parent", kind: "subagent")
        try write(log(session: "parent", input: 20) + log(session: "child", input: 30),
                  to: root.appendingPathComponent("logs/unified.jsonl"))

        let result = try await scan(root)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 50)
        XCTAssertGreaterThan(result.rejectedMetadataRows, 0)
    }

    func testSubagentDirectoryBlocksParentSnapshotWhenChildFilesAreMissing() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "parent")
        try FileManager.default.createDirectory(at: usageURL(root, id: "parent").deletingLastPathComponent().appendingPathComponent("subagents"),
                                                withIntermediateDirectories: true)

        let result = try await scan(root)

        XCTAssertTrue(result.series.daily.isEmpty)
        XCTAssertNil(result.usageHistory)
        XCTAssertGreaterThan(result.rejectedMetadataRows, 0)
    }

    func testChildSummaryWithoutUsageStillBlocksParentSnapshot() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "parent")
        try writeJSON(["info": ["id": "child"], "parent_session_id": "parent", "session_kind": "subagent"],
                      to: usageURL(root, id: "child").deletingLastPathComponent().appendingPathComponent("summary.json"))

        let result = try await scan(root)

        XCTAssertNil(result.usageHistory)
        XCTAssertGreaterThan(result.rejectedMetadataRows, 0)
    }

    func testMissingSummaryAndDuplicateSessionPathsAreNotGuessed() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "missing-summary")
        try FileManager.default.removeItem(at: usageURL(root, id: "missing-summary").deletingLastPathComponent().appendingPathComponent("summary.json"))
        try writeSession(root: root, id: "same-id")
        let duplicate = root.appendingPathComponent("sessions/relocated/same-id")
        try writeJSON(snapshot(id: "same-id"), to: duplicate.appendingPathComponent("usage.json"))
        try writeJSON(["info": ["id": "same-id"]], to: duplicate.appendingPathComponent("summary.json"))

        let result = try await scan(root)

        XCTAssertTrue(result.series.daily.isEmpty)
        XCTAssertNil(result.usageHistory)
        XCTAssertGreaterThan(result.rejectedMetadataRows, 0)
    }

    func testUnscopedLogsAreExcludedWhenSnapshotOverlapCannotBeResolved() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        try write(log(session: nil, input: 60), to: root.appendingPathComponent("logs/unified.jsonl"))

        let result = try await scan(root)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(result.rejectedMetadataRows, 1)
    }

    func testOngoingTurnWaitsForNextCompletedSnapshot() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        try write(log(session: "main", input: 60), to: root.appendingPathComponent("logs/unified.jsonl"))

        let result = try await scan(root)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(result.rejectedMetadataRows, 0)
    }

    func testMalformedSnapshotsKeepLegacyUsageAndWarning() async throws {
        for scenario in ["json", "negative", "fractional", "overflow", "cache", "models", "duplicate-turn", "date"] {
            let root = try fixture()
            try writeSession(root: root, id: "main")
            try write(log(session: "main", input: 60), to: root.appendingPathComponent("logs/unified.jsonl"))
            var object = snapshot(id: "main")
            var row = turn()
            switch scenario {
            case "negative": row["inputTokens"] = -1
            case "fractional": row["inputTokens"] = 1.5
            case "overflow": row["inputTokens"] = "18446744073709551616"
            case "cache": row["cachedReadTokens"] = 101
            case "models": row["modelUsage"] = ["grok-build": metrics(input: 90)]
            case "date": row["endedAt"] = "not-a-date"
            default: break
            }
            object["turns"] = scenario == "duplicate-turn" ? [row, row] : [row]
            if scenario == "json" { try write("{", to: usageURL(root, id: "main")) }
            else { try writeJSON(object, to: usageURL(root, id: "main")) }

            let result = try await scan(root)

            XCTAssertEqual(result.series.daily.first?.totalTokens, 60, scenario)
            XCTAssertGreaterThan(result.rejectedMetadataRows, 0, scenario)
        }
    }

    func testUnreadableUsageFileKeepsLegacyUsageAndReportsFailure() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        try write(log(session: "main", input: 60), to: root.appendingPathComponent("logs/unified.jsonl"))
        let files = GrokUsageReadFailureFiles(failingPath: usageURL(root, id: "main").path)
        let scanner = GrokLogUsageScanner(files: files, environment: FakeEnvironment(["GROK_HOME": root.path]))

        let scanned = await scanner.scan(now: instant, pricing: TestPricing.bundled)
        let result = try XCTUnwrap(scanned)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 60)
        XCTAssertEqual(result.readFailureCount, 1)
        XCTAssertNotNil(result.readWarning)
    }

    func testCancellationDuringFinalUsageReadDiscardsRecordsAndFailureDiagnostics() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        let usagePath = usageURL(root, id: "main").path
        let sessions = root.appendingPathComponent("sessions")
        for failsAfterCancellation in [false, true] {
            let files = GrokUsageCancelledFiles(path: usagePath, failsAfterCancellation: failsAfterCancellation)
            let diagnostics = DiagnosticEventRecorder()
            let result = await Task { GrokSessionUsageScanner(files: files).collect(root: sessions) }.value
            XCTAssertNil(result, "cancelled read must not return a completed collection")
            XCTAssertTrue(diagnostics.events.isEmpty, "cancelled read must not report a storage failure")
        }
    }

    func testEndedAtDeterminesLocalDay() async throws {
        let root = try fixture()
        let endedAt = "2026-11-01T23:59:00Z"
        try writeSession(root: root, id: "main", endedAt: endedAt)

        let ended = try XCTUnwrap(OpenUsageISO8601.date(from: endedAt))
        let scanned = await scanner(root).scan(now: ended.addingTimeInterval(60), pricing: TestPricing.bundled)
        let result = try XCTUnwrap(scanned)

        XCTAssertEqual(result.series.daily.first?.date, DailyUsageAccumulator.dayKey(from: ended))
    }

    func testProviderRefreshIncludesCompletedTurnWithoutNativeLog() async throws {
        let root = try fixture()
        try writeSession(root: root, id: "main")
        let now = instant
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: FakeFiles([
                GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"token","expires_at":"2099-01-01T00:00:00Z"}}"#
            ]), environment: FakeEnvironment(), now: { now }),
            usageClient: GrokUsageClient(httpClient: GrokSessionUsageHTTP()), logUsageScanner: scanner(root),
            sharedUsage: UsageCollectionCoordinator(collectors: []), now: { now }, pricing: { TestPricing.bundled }
        )

        let result = await provider.refresh()

        XCTAssertNil(result.errorCategory)
        XCTAssertNil(result.warning)
        XCTAssertEqual(result.usageHistory?.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(result.usageHistory?.series.daily.first?.costUSD, 0.25)
        XCTAssertTrue(result.lines.contains { $0.label == "Today" })
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("GrokSessionUsageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func scanner(_ root: URL) -> GrokLogUsageScanner {
        GrokLogUsageScanner(environment: FakeEnvironment(["GROK_HOME": root.path]))
    }

    private func scan(_ root: URL) async throws -> LogUsageScan {
        let result = await scanner(root).scan(now: instant, pricing: TestPricing.bundled)
        return try XCTUnwrap(result)
    }

    private func usageURL(_ root: URL, id: String) -> URL {
        root.appendingPathComponent("sessions/project/\(id)/usage.json")
    }

    private func writeSession(
        root: URL, id: String, input: Int = 100, ticks: Int = 2_500_000_000,
        model: String = "grok-build", parent: String? = nil, kind: String? = nil,
        endedAt: String = "2026-11-01T10:00:00Z"
    ) throws {
        let url = usageURL(root, id: id)
        try writeJSON(snapshot(id: id, input: input, ticks: ticks, model: model, endedAt: endedAt), to: url)
        var summary: [String: Any] = ["info": ["id": id, "cwd": "/synthetic/project"]]
        summary["parent_session_id"] = parent
        summary["session_kind"] = kind
        try writeJSON(summary, to: url.deletingLastPathComponent().appendingPathComponent("summary.json"))
    }

    private func writeIncomplete(root: URL, id: String, date: Date, modelOnly: Bool = false) throws {
        let endedAt = OpenUsageISO8601.string(from: date)
        try writeSession(root: root, id: id, endedAt: endedAt)
        var object = snapshot(id: id, endedAt: endedAt)
        var row = turn(endedAt: endedAt)
        if modelOnly {
            var usage = metrics()
            usage["usageIsIncomplete"] = true
            row["modelUsage"] = ["grok-build": usage]
        } else { row["usageIsIncomplete"] = true }
        object["turns"] = [row]
        try writeJSON(object, to: usageURL(root, id: id))
    }

    private func snapshot(
        id: String, input: Int = 100, ticks: Int = 2_500_000_000,
        model: String = "grok-build", endedAt: String = "2026-11-01T10:00:00Z"
    ) -> [String: Any] {
        ["sessionId": id, "updatedAt": endedAt, "session": metrics(input: input, ticks: ticks),
         "turns": [turn(input: input, ticks: ticks, model: model, endedAt: endedAt)]]
    }

    private func turn(
        input: Int = 100, ticks: Int = 2_500_000_000, model: String = "grok-build",
        endedAt: String = "2026-11-01T10:00:00Z"
    ) -> [String: Any] {
        let usage = metrics(input: input, ticks: ticks)
        var row = usage
        row["turnNumber"] = 1
        row["endedAt"] = endedAt
        row["modelUsage"] = [model: usage]
        return row
    }

    private func metrics(
        input: Int = 100, output: Int = 20, read: Int = 30, write: Int = 20,
        reasoning: Int = 7, ticks: Int = 2_500_000_000, calls: Int = 1
    ) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output, "cachedReadTokens": read,
         "cacheCreationTokens": write, "reasoningTokens": reasoning, "totalTokens": input + output,
         "modelCalls": calls, "costUsdTicks": ticks]
    }

    private func log(session: String?, input: Int) -> String {
        let sid = session.map { ",\"sid\":\"\($0)\"" } ?? ""
        return """
        {"pid":1\(sid),"msg":"backend_search: model switch","ctx":{"model_id":"grok-build","api_backend":"Responses"}}
        {"ts":"2026-11-01T11:00:00Z","pid":1\(sid),"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":\(input),"completion_tokens":0}}

        """
    }

    private func writeJSON(_ object: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try write(String(decoding: data, as: UTF8.self), to: url)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private struct GrokUsageReadFailureFiles: TextFileAccessing {
    let failingPath: String
    private let local = LocalTextFileAccessor()

    func exists(_ path: String) -> Bool { local.exists(path) }
    func readText(_ path: String) throws -> String {
        if path == failingPath { throw CocoaError(.fileReadNoPermission) }
        return try local.readText(path)
    }
    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
}

private struct GrokSessionUsageHTTP: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: request.url == GrokUsageClient.creditsConfigURL
                     ? GrokCreditsFixtures.capturedResponseBody : Data("{}".utf8))
    }
}

private struct GrokUsageCancelledFiles: TextFileAccessing {
    let path: String
    let failsAfterCancellation: Bool
    private let local = LocalTextFileAccessor()

    func exists(_ path: String) -> Bool { local.exists(path) }

    func readText(_ path: String) throws -> String {
        let text = try local.readText(path)
        if path == self.path {
            withUnsafeCurrentTask { $0?.cancel() }
            if failsAfterCancellation { throw CocoaError(.fileReadUnknown) }
        }
        return text
    }

    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { throw CocoaError(.fileWriteNoPermission) }
}
