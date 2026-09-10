import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetCreditFetchTests: XCTestCase {
    func testNullResetCreditCountMarksRefreshDegradedAndPreservesUsageBodyCount() async {
        await assertDegradedFallback(resetCreditsBody: #"{"available_count":null}"#)
    }

    func testInvalidJSONMarksRefreshDegradedAndPreservesUsageBodyCount() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ResetCreditLogTests.\(UUID())")
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        await assertDegradedFallback(resetCreditsBody: "not-json")

        let logs = try String(contentsOf: directory.appendingPathComponent("OpenUsage.log"), encoding: .utf8)
        let warnings = logs.split(separator: "\n").filter { $0.contains("[WARN]") || $0.contains("[ERROR]") }
        XCTAssertEqual(warnings.count, 1, logs)
        XCTAssertTrue(warnings.first?.contains("[WARN]") == true, logs)
        XCTAssertTrue(warnings.first?.contains("operation=reset_credit_fetch") == true, logs)
        XCTAssertFalse(logs.contains("not-json"), logs)
    }

    func testNonNumericResetCreditCountMarksRefreshDegradedAndPreservesUsageBodyCount() async {
        await assertDegradedFallback(resetCreditsBody: #"{"available_count":"unavailable"}"#)
    }

    func testBooleanResetCreditCountMarksRefreshDegradedAndPreservesUsageBodyCount() async {
        await assertDegradedFallback(resetCreditsBody: #"{"available_count":true}"#)
    }

    func testZeroResetCreditCountRemainsSuccessful() async {
        await assertSuccessfulCount(resetCreditsBody: #"{"available_count":0}"#, count: 0)
    }

    func testNumericStringResetCreditCountRemainsSuccessful() async {
        await assertSuccessfulCount(resetCreditsBody: #"{"available_count":"2.8"}"#, count: 2)
    }

    private func assertDegradedFallback(
        resetCreditsBody: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let diagnostics = DiagnosticEventRecorder()
        let provider = makeProvider(resetCreditsBody: resetCreditsBody)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.isDegraded, true, file: file, line: line)
        XCTAssertNil(snapshot.errorCategory, file: file, line: line)
        XCTAssertEqual(snapshot.line(label: "Session"), .progress(
            label: "Session", used: 25, limit: 100, format: .percent,
            periodDurationMs: CodexUsageMapper.sessionPeriodMs
        ), file: file, line: line)
        XCTAssertEqual(snapshot.line(label: "Rate Limit Resets"), .values(
            label: "Rate Limit Resets",
            values: [MetricValue(number: 3, kind: .count, label: "available")]
        ), file: file, line: line)
        XCTAssertEqual(
            diagnostics.events.filter { $0.operation == .resetCreditFetch },
            [DiagnosticEvent(.resetCreditFetch, result: .degraded, category: .decoding, providerID: "codex")],
            file: file, line: line
        )
    }

    private func assertSuccessfulCount(
        resetCreditsBody: String,
        count: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let diagnostics = DiagnosticEventRecorder()
        let provider = makeProvider(resetCreditsBody: resetCreditsBody)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.isDegraded, file: file, line: line)
        XCTAssertNil(snapshot.errorCategory, file: file, line: line)
        XCTAssertEqual(snapshot.line(label: "Rate Limit Resets"), .values(
            label: "Rate Limit Resets",
            values: [MetricValue(number: count, kind: .count, label: "available")]
        ), file: file, line: line)
        XCTAssertEqual(
            diagnostics.events.filter { $0.operation == .resetCreditFetch },
            [DiagnosticEvent(.resetCreditFetch, result: .success, providerID: "codex")],
            file: file, line: line
        )
    }

    private func makeProvider(resetCreditsBody: String) -> CodexProvider {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"rate_limit":{"primary_window":{"used_percent":25}},"rate_limit_reset_credits":{"available_count":3}}"#.utf8
                ))
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(resetCreditsBody.utf8))
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        return CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-reset-credit-fixture"]),
                files: FakeFiles([
                    "/tmp/codex-reset-credit-fixture/auth.json": #"{"tokens":{"access_token":"fixture-token"}}"#
                ]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            includePiUsage: false,
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { TestPricing.bundled }
        )
    }
}
