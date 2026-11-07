import XCTest
@testable import OpenUsage

final class CodexCompletedUsageWarningTests: XCTestCase {
    private let timestamp = "2026-11-06T01:00:00Z"

    @MainActor
    func testCollectionLimitsStayInDiagnosticsWhileReadFailuresRemainVisible() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: timestamp)).addingTimeInterval(60)
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/ambiguous.jsonl": rollout(initial: 500, last: 500).joined(separator: "\n")
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": home.path]),
                files: FakeFiles([home.appendingPathComponent("auth.json").path:
                    #"{"tokens":{"access_token":"token"}}"#]), keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: FakeHTTPClient(response: .init(
                statusCode: 200, headers: [:], body: Data(
                    #"{"rate_limit":{"primary_window":{"used_percent":15,"reset_after_seconds":60}},"credits":[]}"#.utf8
                )
            ))),
            logUsageScanner: CodexLogFixture.scanner(home: home), includeSharedUsage: false,
            now: { now }, pricing: { .empty }
        )

        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.warning)
        XCTAssertTrue(snapshot.warningPresentation?.isEmpty != false)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 1_000)
        XCTAssertNil(snapshot.usageHistory?.series.daily.first?.costUSD)
        XCTAssertTrue(diagnostics.events.contains {
            $0.operation == .historyScan && $0.result == .degraded && $0.category == .decoding
        })

        try Data("invalid compressed log".utf8).write(to: home.appendingPathComponent("sessions/unreadable.jsonl.zst"))
        let failedRead = await provider.refresh()
        XCTAssertEqual(failedRead.warning, "Some local usage files could not be read. Usage history may be incomplete.")
        XCTAssertNotNil(failedRead.line(label: "Session"))
        XCTAssertEqual(failedRead.usageHistory, snapshot.usageHistory)
    }

    func testUpdatedLastUsageConfirmsCompletedResponseBeforeTerminalError() {
        for terminal in ["task_complete", "turn_aborted"] {
            for initial in [0, 100] {
                let events = parse(rollout(initial: initial, last: 500, terminal: terminal))
                let scan = aggregate(events + events)
                XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, initial + 500)
                XCTAssertEqual(scan.rejectedMetadataRows, 0)
                XCTAssertNil(scan.metadataWarning)
            }
        }
    }

    func testUnchangedOrDifferentLastUsageDoesNotConfirmAmbiguousResponse() {
        for (initial, last) in [(500, 500), (100, 300)] {
            let scan = aggregate(parse(rollout(initial: initial, last: last)))
            XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, initial + 500)
            XCTAssertEqual(scan.rejectedMetadataRows, 1)
            XCTAssertNotNil(scan.metadataWarning)
        }
    }

    func testMissingOrInvalidPreviousLastUsageKeepsAmbiguityWarning() {
        for previousLast in [nil, ["input_tokens": -1]] as [[String: Int]?] {
            let lines = [context(), count(last: previousLast, total: 100), record(),
                         count(last: usage(500), total: 600), terminal("task_complete")]
            XCTAssertEqual(aggregate(parse(lines)).rejectedMetadataRows, 1)
        }
    }

    func testVersionNineteenCacheReparsesAndPersistsConfirmedUsage() async throws {
        let content = rollout(initial: 100, last: 500).joined(separator: "\n")
        let home = try CodexLogFixture.makeHome(files: ["sessions/completed.jsonl": content])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let directory = home.appendingPathComponent("cache")
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: .init(
            namespace: "codex", schemaVersion: 19, directory: directory, writeDebounce: .milliseconds(1)
        ))
        let rejected = CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(OpenUsageISO8601.date(from: timestamp)), model: "gpt-5.2",
            input: 500, cached: 0, output: 0, reasoning: 0, total: 500, invalidMetadata: true
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "completed") { _ in [rejected] }
        await old.waitForPendingWritesForTesting()

        let persistence = JSONLScanCachePersistence(
            namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion,
            directory: directory, writeDebounce: .milliseconds(1)
        )
        let rebuilt = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let events = await rebuilt.items(
            from: files, since: .distantPast, cacheIdentity: "completed", parse: CodexLogUsageScanner.parseFile
        )
        let scan = aggregate(try XCTUnwrap(events))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 600)
        XCTAssertEqual(scan.rejectedMetadataRows, 0)
        await rebuilt.waitForPendingWritesForTesting()

        let reloaded = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let cached = await reloaded.items(from: files, since: .distantPast, cacheIdentity: "completed") { _ in
            XCTFail("Expected the confirmed usage to be persisted")
            return []
        }
        XCTAssertEqual(aggregate(try XCTUnwrap(cached)).rejectedMetadataRows, 0)
    }

    private func rollout(initial: Int, last: Int, terminal: String = "task_complete") -> [String] {
        [context(), count(last: usage(initial), total: initial, at: "2026-11-06T00:59:00Z"), record(),
         count(last: usage(last), total: initial + 500),
         count(last: usage(last), total: initial + 500), self.terminal(terminal)]
    }

    private func context() -> String {
        line(type: "turn_context", payload: ["turn_id": "turn", "model": "gpt-5.2"])
    }

    private func record() -> String {
        line(type: "token_usage_record", payload: [
            "session_id": "session", "turn_id": "turn", "response_id": "response", "usage": usage(500)
        ])
    }

    private func terminal(_ type: String) -> String {
        line(type: "event_msg", payload: ["type": type, "turn_id": "turn", "error": ["message": "response failed"]])
    }

    private func usage(_ input: Int) -> [String: Int] {
        CodexLogFixture.usage(input: input, output: 0)
    }

    private func count(last: [String: Int]?, total: Int, at: String? = nil) -> String {
        CodexLogFixture.tokenCount(timestamp: at ?? timestamp, last: last, totals: usage(total))
    }

    private func line(type: String, payload: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [
            "timestamp": timestamp, "type": type, "payload": payload
        ]), as: UTF8.self)
    }

    private func parse(_ lines: [String]) -> [CodexLogUsageScanner.Event] {
        CodexLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
    }

    private func aggregate(_ events: [CodexLogUsageScanner.Event]) -> LogUsageScan {
        CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
    }
}
