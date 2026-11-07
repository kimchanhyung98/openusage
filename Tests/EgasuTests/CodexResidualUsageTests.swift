import XCTest
@testable import Egasu

final class CodexResidualUsageTests: XCTestCase {
    private let timestamp = "2026-11-02T01:00:00Z"
    private let nextTimestamp = "2026-11-02T01:01:00Z"

    func testResidualEqualToRecordedUsageSurvivesAggregationAndCopiedFiles() {
        let events = parse(partialLines())
        XCTAssertEqual(events.map(\.input), [200, 100, 100])
        assertUsage(events, tokens: 400)
        assertUsage(events + parse(partialLines()), tokens: 400)
    }

    func testIndependentMatchingRecordDoesNotEraseConfirmedResidual() {
        let partial = parse(partialLines())
        let independent = parse([context(), record("independent")])
        for events in [partial + independent, independent + partial] {
            assertUsage(events, tokens: 500)
        }
    }

    func testMoreCompleteCopyReplacesOnlyTheSameSnapshotsResidual() {
        let older = parse(partialLines())
        let newer = parse(partialLines() + [record("later")])
        let independent = parse([context(), record("independent")])
        XCTAssertEqual(newer.map(\.input), [200, 100, 100])
        XCTAssertEqual(newer.compactMap(\.usageRecordID), ["session:one", "session:later"])
        for events in [older + newer + independent, independent + newer + older] {
            assertUsage(events, tokens: 500)
        }
    }

    func testEqualUsageInSeparateBoundariesSurvivesCopiedFiles() {
        let lines = [context(), record("one"), count(last: 100, total: 100),
                     count(last: 100, total: 200), count(last: 100, total: 300)]
        let events = parse(lines)
        XCTAssertEqual(events.map(\.input), [100, 100, 100])
        assertUsage(events + parse(lines), tokens: 300)
    }

    func testCompleteCopyEvidenceSurvivesAnEarlierRecordOnlyCopy() {
        let recordOnly = parse([context(), record("one")])
        let older = parse([context(), count(last: 100, total: 100)])
        let newer = parse([context(), count(last: 100, total: 100), record("one")])
        for events in [recordOnly + older + newer, newer + older + recordOnly] {
            assertUsage(events, tokens: 100)
        }
    }

    func testVersionEighteenCacheReparsesAndPersistsResidualProvenance() async throws {
        let home = try CodexLogFixture.makeHome(files: [
            "sessions/partial.jsonl": partialLines().joined(separator: "\n"),
            "sessions/newer.jsonl": (partialLines() + [record("later")]).joined(separator: "\n"),
            "sessions/independent.jsonl": [context(), record("independent")].joined(separator: "\n")
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = UsageFileDiscovery.files(under: [home.appendingPathComponent("sessions")]) {
            $0.pathExtension == "jsonl"
        }.files
        let directory = home.appendingPathComponent("cache")
        let now = try XCTUnwrap(EgasuISO8601.date(from: nextTimestamp))
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence: .init(namespace: "codex", schemaVersion: 18, directory: directory, writeDebounce: .milliseconds(1))
        )
        let stale = CodexLogUsageScanner.Event(
            timestamp: now, model: "gpt-5.2", input: 999, cached: 0, output: 0, reasoning: 0, total: 999
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "fixture") { _ in [stale] }
        await old.waitForPendingWritesForTesting()

        let persistence = JSONLScanCachePersistence(
            namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion,
            directory: directory, writeDebounce: .milliseconds(1)
        )
        let rebuilt = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let scanner = CodexLogUsageScanner(incrementalScanner: rebuilt, cacheIdentityOverride: "fixture", rootsOverride: [home])
        for _ in 0..<2 {
            let scan = await scanner.scan(now: now, pricing: TestPricing.bundled)
            XCTAssertEqual(scan?.series.daily.first?.totalTokens, 500)
        }
        await rebuilt.waitForPendingWritesForTesting()
        let reloaded = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let cached = await reloaded.items(from: files, since: .distantPast, cacheIdentity: "fixture") { _ in
            XCTFail("Expected persisted parse cache")
            return []
        }
        assertUsage(try XCTUnwrap(cached), tokens: 500)
    }

    private func assertUsage(_ events: [CodexLogUsageScanner.Event], tokens: Int, file: StaticString = #filePath, line: UInt = #line) {
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, tokens, file: file, line: line)
        let expected = CodexLogUsageScanner.aggregate(events: [
            .init(timestamp: EgasuISO8601.date(from: timestamp)!, model: "gpt-5.2",
                  input: tokens, cached: 0, output: 0, reasoning: 0, total: tokens)
        ], since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) },
                       expected.series.daily.reduce(0) { $0 + ($1.costUSD ?? 0) }, accuracy: 0.0000001, file: file, line: line)
        XCTAssertEqual(scan.rejectedNumericRows, 0, file: file, line: line)
        XCTAssertEqual(scan.rejectedMetadataRows, 0, file: file, line: line)
    }

    private func partialLines() -> [String] {
        [context(), count(last: 200, total: 200, at: timestamp), record("one"), count(last: 200, total: 400)]
    }

    private func context() -> String {
        line(type: "turn_context", payload: ["turn_id": "turn", "model": "gpt-5.2"])
    }

    private func record(_ response: String) -> String {
        line(type: "token_usage_record", payload: [
            "session_id": "session", "turn_id": "turn", "response_id": response,
            "usage": CodexLogFixture.usage(input: 100, output: 0)
        ])
    }

    private func count(last: Int, total: Int, at: String? = nil) -> String {
        CodexLogFixture.tokenCount(timestamp: at ?? nextTimestamp, last: CodexLogFixture.usage(input: last, output: 0),
                                  totals: CodexLogFixture.usage(input: total, output: 0))
    }

    private func line(type: String, payload: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [
            "timestamp": nextTimestamp, "type": type, "payload": payload
        ]), as: UTF8.self)
    }

    private func parse(_ lines: [String]) -> [CodexLogUsageScanner.Event] {
        CodexLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
    }
}
