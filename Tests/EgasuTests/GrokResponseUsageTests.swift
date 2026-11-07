import XCTest
@testable import Egasu

final class GrokResponseUsageTests: XCTestCase {
    func testResponsesOutputAlreadyIncludesReasoning() {
        for (input, cached, output, reasoning, tokens, cost) in [
            (131, 128, 624, 246, 755, 0.003814),
            (6_003, 1_984, 711, 388, 6_714, 0.013296)
        ] {
            let scan = parse([
                applied(backend: "Responses"),
                usage(input: input, cached: cached, output: output, reasoning: reasoning)
            ])
            assertUsage(scan, tokens: tokens, cost: cost)
        }
    }

    func testChatCompletionsAndUnmarkedModelKeepSeparateReasoning() {
        for backend in [nil, "ChatCompletions"] as [String?] {
            assertUsage(parse([applied(backend: backend), usage()]), tokens: 1_001, cost: 0.005290)
        }
    }

    func testBackendChangesOnlyWithAppliedSessionModel() {
        let scan = parse([
            applied(backend: "Responses"), usage(),
            line("model changed", ctx: ["model": "grok-4.6", "api_backend": "ChatCompletions"]), usage(),
            applied(backend: "ChatCompletions"), usage()
        ])
        assertUsage(scan, tokens: 2_511, cost: 0.012918)
    }

    func testExplicitSessionBackendSurvivesOtherSessionsAndProcessCatalog() {
        let scan = parse([
            applied(backend: "Responses", sid: "first"),
            applied(backend: "ChatCompletions", sid: "second"),
            line("model catalog: notifying clients", sid: nil, ctx: ["current_model_id": "grok-4.6"]),
            usage(sid: "first"), usage(sid: "second"), usage(sid: "first")
        ])
        assertUsage(scan, tokens: 2_511, cost: 0.012918)
    }

    func testRestartAndUnmarkedModelApplicationClearOldBackend() {
        let suffixes = [
            [line("process resource limits", sid: nil, ctx: [:]),
             line("model catalog: notifying clients", sid: nil, ctx: ["current_model_id": "grok-4.6"])],
            [applied(backend: nil)]
        ]
        for suffix in suffixes {
            assertUsage(parse([applied(backend: "Responses"), usage()] + suffix + [usage()]),
                        tokens: 1_756, cost: 0.009104)
        }
    }

    func testResponsesReasoningStillRequiresValidNumbers() {
        let scan = parse([applied(backend: "Responses"), usage(reasoning: -1), usage()])
        assertUsage(scan, tokens: 755, cost: 0.003814, rejected: 1)
        XCTAssertNotNil(scan.numericWarning)
    }

    private func assertUsage(
        _ scan: LogUsageScan, tokens: Int, cost: Double, rejected: Int = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, tokens, file: file, line: line)
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), cost,
                       accuracy: 0.0000001, file: file, line: line)
        XCTAssertEqual(scan.rejectedNumericRows, rejected, file: file, line: line)
        XCTAssertEqual(scan.rejectedMetadataRows, 0, file: file, line: line)
    }

    private func applied(backend: String?, sid: String = "session") -> String {
        var ctx = ["new_model": "grok-4.6"]
        ctx["api_backend"] = backend
        return line("backend_search: model switch", sid: sid, ctx: ctx)
    }

    private func usage(
        input: Int = 131, cached: Int = 128, output: Int = 624, reasoning: Int = 246,
        sid: String = "session"
    ) -> String {
        line("shell.turn.inference_done", sid: sid, ctx: [
            "prompt_tokens": input, "cached_prompt_tokens": cached,
            "completion_tokens": output, "reasoning_tokens": reasoning
        ])
    }

    private func line(_ message: String, sid: String? = "session", ctx: [String: Any]) -> String {
        var object: [String: Any] = ["ts": "2026-11-02T01:00:00Z", "pid": 7, "msg": message, "ctx": ctx]
        object["sid"] = sid
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func parse(_ lines: [String]) -> LogUsageScan {
        GrokLogUsageScanner.parse(lines.joined(separator: "\n"), since: .distantPast, pricing: TestPricing.bundled)
    }
}
