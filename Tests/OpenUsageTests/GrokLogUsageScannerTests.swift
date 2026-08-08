import XCTest
@testable import OpenUsage

final class GrokLogUsageScannerTests: XCTestCase {
    private let since = OpenUsageISO8601.date(from: "2026-06-01T00:00:00.000Z")!

    func testAttributesTokensToPerProcessModelAndPrices() {
        // fixture: pid 100은 grok-build, pid 200은 grok-composer-2.5-fast — token row는 각 process의 현재 model로 가격 산정
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":100,"msg":"model catalog: notifying clients","ctx":{"current_model_id":"grok-build"}}
        {"ts":"2026-06-10T09:00:00.000Z","pid":200,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":100,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":200,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":1000000,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        let day = usage.series.daily.first { $0.date == "2026-06-10" }
        XCTAssertEqual(day?.totalTokens, 4_000_000)
        // 계산: grok-build 입력 1M × $1 + 출력 1M × $2 = $3, composer-2.5-fast 입력 1M × $3 + 출력 1M × $15 = $18
        XCTAssertEqual(day?.costUSD ?? 0, 21.0, accuracy: 0.0001)
        let models = usage.modelUsage?.daily.first { $0.date == "2026-06-10" }?.models ?? []
        XCTAssertEqual(Set(models.map(\.model)), Set(["grok-build", "grok-composer-2.5-fast"]))
    }

    func testTracksMidProcessModelSwitch() {
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":7,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-12T10:00:00.000Z","pid":7,"msg":"model changed","ctx":{"model":"grok-composer-2.5-fast"}}
        {"ts":"2026-06-12T11:00:00.000Z","pid":7,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":0,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 첫 row는 grok-build($1/M input), switch 이후 row는 composer-2.5-fast($3/M)로 가격 산정
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 4.0, accuracy: 0.0001)
    }

    func testUsesCachedReadRateForCachedPromptTokens() {
        // fixture: 1M prompt token 중 800k는 cache read (grok-build: read $0.2/M vs input $1/M)
        let log = """
        {"ts":"2026-06-12T08:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-12T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"cached_prompt_tokens":800000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 200k input @ $1/M ($0.2) + 800k cache read @ $0.2/M ($0.16) = 총 $0.36
        XCTAssertEqual(usage.series.daily.first?.costUSD ?? 0, 0.36, accuracy: 0.0001)
    }

    func testSkipsRowsWithoutTokenFieldsAndOutsideWindow() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-05-30T09:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"loop_index":3,"model_elapsed_ms":10}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // window 내 token 보유 row만 집계 — window 이전 row·token 없는 row 제외
        XCTAssertEqual(usage.series.daily.count, 1)
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
    }

    func testUnpricedModelIsExcludedFromTotalsButWarns() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        {"ts":"2026-06-10T11:00:00.000Z","pid":2,"msg":"model changed","ctx":{"model":"grok-build"}}
        {"ts":"2026-06-10T12:00:00.000Z","pid":2,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":500000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 가격 산정 불가 token은 표시 합계에서 제외 — warning triangle로만 노출해 token·달러 정합 유지
        XCTAssertEqual(usage.series.daily.first?.totalTokens, 500_000)
        XCTAssertNotNil(usage.series.daily.first?.costUSD)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-unknown-model"])
        XCTAssertEqual(usage.modelUsage?.daily.first?.models.map(\.model), ["grok-build"])
    }

    func testUnpricedModelOnlyLeavesDayUnbacked() {
        let log = """
        {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-unknown-model"}}
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // 가격 산정 가능한 항목이 없는 날은 series entry 없음(→ "No data") — unknown-model warning은 제외 대상 명시
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertEqual(usage.unknownModelsByDay["2026-06-10"], ["grok-unknown-model"])
        XCTAssertEqual(usage.modelUsage?.daily ?? [], [])
    }

    func testUnattributedRowsAreExcludedWithoutWarning() {
        let log = """
        {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
        """

        let usage = GrokLogUsageScanner.parse(log, since: since, pricing: TestPricing.bundled)

        // model 귀속 불가 token은 전 합계에서 제외 — 경고할 model 이름도 없어 unknown-model entry 없음
        XCTAssertTrue(usage.series.daily.isEmpty)
        XCTAssertTrue(usage.unknownModelsByDay.isEmpty)
        XCTAssertEqual(usage.modelUsage?.daily ?? [], [])
    }

    func testScanReadsGrokHomeOverride() async {
        let files = FakeFiles([
            "/custom/grok/logs/unified.jsonl": """
            {"ts":"2026-06-10T09:00:00.000Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}
            {"ts":"2026-06-10T10:00:00.000Z","pid":1,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":1000000,"completion_tokens":0,"reasoning_tokens":0}}
            """
        ])
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") }
        )

        let usage = await scanner.scan(daysBack: 30, now: OpenUsageISO8601.date(from: "2026-06-18T00:00:00.000Z")!, pricing: TestPricing.bundled)

        XCTAssertEqual(usage?.series.daily.first?.totalTokens, 1_000_000)
    }

    func testScanReturnsNilWhenLogMissing() async {
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: FakeFiles(),
            environment: FakeEnvironment(),
            homeDirectory: { URL(fileURLWithPath: "/home/none") },
            readFailureWarning: warnings.record
        )

        let usage = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertNil(usage)
        XCTAssertEqual(warnings.counts, [])
    }

    func testUnreadableLogWarnsOnceUntilItRecovers() async {
        let path = "/custom/grok/logs/unified.jsonl"
        let files = FailingTextFiles(path: path)
        let warnings = GrokWarningRecorder()
        let scanner = GrokLogUsageScanner(
            files: files,
            environment: FakeEnvironment(["GROK_HOME": "/custom/grok"]),
            homeDirectory: { URL(fileURLWithPath: "/home/ignored") },
            readFailureWarning: warnings.record
        )

        _ = await scanner.scan(pricing: TestPricing.bundled)
        _ = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(warnings.counts, [1])

        files.shouldFail = false
        _ = await scanner.scan(pricing: TestPricing.bundled)
        files.shouldFail = true
        _ = await scanner.scan(pricing: TestPricing.bundled)
        XCTAssertEqual(warnings.counts, [1, 1])
    }
}

private final class GrokWarningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int] = []

    var counts: [Int] { lock.withLock { recordedCounts } }

    func record(_ count: Int) {
        lock.withLock { recordedCounts.append(count) }
    }
}

private final class FailingTextFiles: TextFileAccessing, @unchecked Sendable {
    let path: String
    var shouldFail = true

    init(path: String) {
        self.path = path
    }

    func exists(_ path: String) -> Bool { path == self.path }

    func readText(_ path: String) throws -> String {
        if shouldFail { throw TestError.unreadable }
        return ""
    }

    func writeText(_ path: String, _ text: String) throws {}
    func remove(_ path: String) throws {}

    private enum TestError: Error {
        case unreadable
    }
}
