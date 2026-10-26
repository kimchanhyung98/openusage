import Darwin
import XCTest
@testable import OpenUsage

final class JSONLParsingWorkTests: XCTestCase {
    func testLineIterationMatchesSplitForBoundariesAndDataSlices() {
        let inputs = [
            Data(), Data([0x0A]), Data("\n\n".utf8), Data("first".utf8),
            Data("\nfirst\n\nlast".utf8), Data("first\r\nlast\r\n".utf8),
            Data(#"{"text":"escaped\nnewline"}"#.utf8),
            Data([0xFF, 0x0A, 0x00, 0xFE, 0x0A]), Data("한국어\n日本語\n".utf8)
        ]
        for input in inputs {
            XCTAssertEqual(Array(JSONLScanning.lines(in: input)), input.split(separator: 0x0A))
            var padded = Data([0xAA])
            padded.append(input)
            padded.append(0xBB)
            let slice = padded[1..<(padded.count - 1)]
            XCTAssertEqual(Array(JSONLScanning.lines(in: slice)), slice.split(separator: 0x0A))
        }
    }

    func testLineIterationMatchesSplitForDeterministicMixedBytes() {
        var seed: UInt64 = 0xB10C
        for length in 0..<128 {
            var bytes: [UInt8] = []
            for _ in 0..<length {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(seed % 4 == 0 ? 0x0A : UInt8(truncatingIfNeeded: seed >> 32))
            }
            let input = Data(bytes)
            let lines = JSONLScanning.lines(in: input)
            XCTAssertEqual(Array(lines), input.split(separator: 0x0A))
            XCTAssertEqual(Array(lines), input.split(separator: 0x0A))
        }
    }

    func testCodexRetainsModelTierAndTotalsAcrossUnusedRows() {
        let timestamp = "2026-05-12T08:00:00.000Z"
        let lines = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.2"),
            CodexLogFixture.threadSettingsApplied(timestamp: timestamp, serviceTier: "fast"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00.000Z",
                totals: CodexLogFixture.usage(input: 100, output: 20)
            ),
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:02:00.000Z",
                totals: CodexLogFixture.usage(input: 150, output: 30)
            )
        ]
        let expected = CodexLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(expected.map(\.input), [100, 50])
        XCTAssertEqual(expected.map(\.model), ["gpt-5.2", "gpt-5.4"])
        XCTAssertTrue(expected.allSatisfy(\.isFast))
        check(provider: "codex", lines: lines, expected: expected, parse: CodexLogUsageScanner.parseFile)
    }

    func testClaudeRetainsUsageAcrossUnusedRows() {
        let lines = [ClaudeLogFixture.usageLine(
            timestamp: "2026-05-12T08:00:00.000Z", input: 100, output: 20, speed: "fast"
        )]
        let expected = ClaudeLogUsageScanner.parseFile(Data(lines[0].utf8))
        XCTAssertEqual(expected.count, 1)
        check(provider: "claude", lines: lines, expected: expected, parse: ClaudeLogUsageScanner.parseFile)
    }

    func testPiRetainsUsageAcrossUnusedRows() {
        let lines = [#"{"type":"message","timestamp":"2026-05-12T08:00:00.000Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.2","usage":{"input":100,"output":20,"totalTokens":120}}}"#]
        let expected = PiUsageScanner.parseFile(Data(lines[0].utf8))
        XCTAssertEqual(expected.count, 1)
        check(provider: "pi", lines: lines, expected: expected, parse: PiUsageScanner.parseFile)
    }

    private func check<Item: Equatable>(
        provider: String, lines: [String], expected: [Item], parse: (Data) -> [Item]
    ) {
        let benchmarking = ProcessInfo.processInfo.environment["OPENUSAGE_JSONL_BENCHMARK"] == "1"
        let row = "{\"type\":\"response_item\",\"payload\":\"" + String(repeating: "x", count: 1_024) + "\"}\r\n"
        let noise = String(repeating: row, count: benchmarking ? 8_192 : 32)
        let input = Data(("\n" + noise + lines.joined(separator: "\r\n\n" + noise)).utf8)
        for run in 0..<(benchmarking ? 3 : 1) {
            let wallStart = Date()
            let cpuStart = clock()
            let actual = parse(input)
            let cpuSeconds = Double(clock() - cpuStart) / Double(CLOCKS_PER_SEC)
            let wallSeconds = Date().timeIntervalSince(wallStart)
            XCTAssertEqual(actual, expected)
            if benchmarking {
                print("JSONL_BENCH provider=\(provider) run=\(run) bytes=\(input.count) cpu=\(cpuSeconds) wall=\(wallSeconds)")
            }
        }
    }
}
