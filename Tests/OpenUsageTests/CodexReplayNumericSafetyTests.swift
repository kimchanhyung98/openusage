import XCTest
@testable import OpenUsage

final class CodexReplayNumericSafetyTests: XCTestCase {
    private let timestamp = "2026-09-12T10:00:00Z"

    func testCorruptParentReplayPreservesLastValidBaselineForEveryChildGate() {
        let metadata = [
            CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
            CodexLogFixture.forkSessionMeta(timestamp: timestamp),
            #"{"type":"session_meta","payload":{"forked_from_id":"parent"}}"#,
        ]
        for meta in metadata {
            for corrupt in [
                ["input_tokens": -1, "output_tokens": 50],
                ["input_tokens": Int.max, "output_tokens": 50],
            ] {
                let events = CodexLogUsageScanner.parseFile(Data(rollout(meta: meta, corrupt: corrupt).utf8))
                XCTAssertEqual(events.map(\.total), [100])
                XCTAssertEqual(events.map(\.input), [100])
                XCTAssertEqual(events.map(\.output), [0])
                XCTAssertEqual(events.map(\.invalidNumericValues), [false])
                let scan = CodexLogUsageScanner.aggregate(
                    events: events, since: .distantPast, pricing: TestPricing.bundled
                )
                XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
                XCTAssertEqual(scan.rejectedNumericRows, 0)
            }
        }
    }

    func testVersionTwoReplayCacheReparsesAndPersistsTheRecoveredUsage() async throws {
        let content = rollout(
            meta: CodexLogFixture.subagentSessionMeta(timestamp: timestamp),
            corrupt: ["input_tokens": -1, "output_tokens": 50]
        )
        let home = try CodexLogFixture.makeHome(files: ["sessions/replay.jsonl": content])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let directory = home.appendingPathComponent("cache")
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: timestamp))
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence: .init(namespace: "codex", schemaVersion: 2, directory: directory, writeDebounce: .milliseconds(1))
        )
        let poisoned = CodexLogUsageScanner.Event(
            timestamp: now, model: "", input: 0, cached: 0, output: 0, reasoning: 0,
            total: 0, invalidNumericValues: true
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "replay-account") { _ in [poisoned] }
        await old.waitForPendingWritesForTesting()

        let persistence = JSONLScanCachePersistence(
            namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion,
            directory: directory, writeDebounce: .milliseconds(1)
        )
        let rebuilt = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let scanner = CodexLogUsageScanner(
            incrementalScanner: rebuilt, cacheIdentityOverride: "replay-account", rootsOverride: [home]
        )
        let scan = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(scan?.rejectedNumericRows, 0)
        await rebuilt.waitForPendingWritesForTesting()

        let relaunched = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(persistence: persistence)
        let cached = await relaunched.items(
            from: files, since: .distantPast, cacheIdentity: "replay-account"
        ) { _ in [] }
        XCTAssertEqual(cached?.map(\.total), [100])
        XCTAssertEqual(cached?.map(\.invalidNumericValues), [false])
        await relaunched.waitForPendingWritesForTesting()
    }

    private func rollout(meta: String, corrupt: [String: Int]) -> String {
        let epoch = Int(OpenUsageISO8601.date(from: timestamp)!.timeIntervalSince1970)
        return [
            meta,
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-5.4"),
            CodexLogFixture.tokenCount(
                timestamp: timestamp, totals: CodexLogFixture.usage(input: 100, output: 50)
            ),
            CodexLogFixture.tokenCount(timestamp: timestamp, totals: corrupt),
            CodexLogFixture.taskStarted(timestamp: timestamp, startedAt: epoch),
            CodexLogFixture.tokenCount(
                timestamp: timestamp, totals: CodexLogFixture.usage(input: 200, output: 50)
            ),
        ].joined(separator: "\n")
    }
}
