import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class KimiUsageScannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRequestDeltasIncludeBothScopesAndEachTokenBucketOnce() throws {
        let data = try wire([
            request(), usage(scope: "turn"), usage(scope: "session"),
            ["type": "agent.status.updated", "usage": ["total": ["inputOther": 999_999]]],
            ["type": "context.append_loop_event", "event": ["type": "step.end", "usage": ["inputOther": 999_999]]]
        ])
        let parsed = try KimiUsageScanner.parse(data)
        let result = KimiUsageScanner.aggregate([parsed], now: now)

        XCTAssertEqual(parsed.records.map(\.tokens), [190, 190])
        XCTAssertEqual(result.series.daily.first?.totalTokens, 380)
        XCTAssertNil(result.series.daily.first?.costUSD)
        XCTAssertEqual(result.invalidRows, 0)
    }

    func testOnlyConfiguredKimiRequestsWithMatchingAgentAndAliasContribute() throws {
        var wrongAgent = usage()
        wrongAgent["agentId"] = "other-agent"
        let parsed = try KimiUsageScanner.parse(wire([
            request(alias: "other/k3"), usage(alias: "other/k3"),
            request(model: "gpt-4", alias: "kimi-code/custom"), usage(alias: "kimi-code/custom"),
            request(model: "claude-sonnet", alias: "kimi-code/claude"), usage(alias: "kimi-code/claude"),
            request(), wrongAgent,
            usage(alias: "kimi-code/mismatched"),
            request(model: "kimi-for-coding-highspeed"), usage()
        ]))

        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertEqual(parsed.invalidRows, 2)
    }

    func testLatestForkMarkerExcludesEveryCopiedRecord() throws {
        let parsed = try KimiUsageScanner.parse(wire([
            request(), usage(),
            ["type": "forked", "agentId": "main", "time": epochMilliseconds],
            request(), usage(),
            ["type": "forked", "agentId": "main", "time": epochMilliseconds],
            request(), usage()
        ]))

        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertEqual(parsed.records.first?.tokens, 190)
    }

    func testLocalDateBoundaryIncludesPreviousThirtyDaysAndExcludesFuture() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3_600)!
        let midnight = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -30, to: midnight)!
        let records = [
            KimiUsageScanner.Record(timestamp: midnight, tokens: 10),
            .init(timestamp: midnight.addingTimeInterval(-1), tokens: 20),
            .init(timestamp: earliest, tokens: 30),
            .init(timestamp: earliest.addingTimeInterval(-1), tokens: 40),
            .init(timestamp: now.addingTimeInterval(1), tokens: 50)
        ]
        let result = KimiUsageScanner.aggregate([.init(records: records)], now: now, calendar: calendar)

        XCTAssertEqual(result.series.daily.map(\.totalTokens), [10, 20, 30])
        XCTAssertEqual(result.series.daily.first?.date, DailyUsageAccumulator.dayKey(from: midnight, calendar: calendar))
    }

    func testMalformedCompleteRowsWarnAndPartialTrailingWriteWaits() throws {
        let complete = try wire([request(), usage()])
        let next = try JSONSerialization.data(withJSONObject: usage())
        var partial = complete
        partial.append(Data("not-json\n".utf8))
        partial.append(next.prefix(next.count / 2))
        let pending = try KimiUsageScanner.parse(partial)
        XCTAssertEqual(pending.records.count, 1)
        XCTAssertEqual(pending.invalidRows, 1)

        var finished = complete
        finished.append(next)
        finished.append(0x0A)
        let parsed = try KimiUsageScanner.parse(finished)
        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(parsed.invalidRows, 0)
    }

    func testInvalidNumbersAndMissingTimestampAreExcluded() throws {
        var rows = [request()]
        for value: Any in [-1, 0.5, true, "10"] {
            var row = usage()
            var tokens = row["usage"] as! [String: Any]
            tokens["inputOther"] = value
            row["usage"] = tokens
            rows.append(row)
        }
        var missingTime = usage()
        missingTime.removeValue(forKey: "time")
        rows += [missingTime, usage()]
        let result = KimiUsageScanner.aggregate([try KimiUsageScanner.parse(wire(rows))], now: now)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 190)
        XCTAssertEqual(result.invalidRows, 5)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testFutureWireVersionFailsInsteadOfReturningEmptyHistory() throws {
        let data = try wire([request(), usage()], version: "2.0")
        XCTAssertThrowsError(try KimiUsageScanner.parse(data)) {
            XCTAssertEqual(($0 as? KimiHistoryError)?.errorCategory, .decoding)
        }
    }

    func testOverflowingAggregateKeepsValidRowsAndWarns() {
        let parsed = KimiUsageScanner.ParsedFile(records: [
            .init(timestamp: now, tokens: Int.max),
            .init(timestamp: now, tokens: 1)
        ])
        let result = KimiUsageScanner.aggregate([parsed], now: now)

        XCTAssertEqual(result.series.daily.first?.totalTokens, Int.max)
        XCTAssertEqual(result.invalidRows, 1)
    }

    func testScannerUsesConfiguredHomeAndOnlyAgentWireFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("sessions/workspace/session/agents/main/wire.jsonl")
        let child = root.appendingPathComponent("sessions/workspace/session/agents/agent-0/wire.jsonl")
        let backup = root.appendingPathComponent("sessions/workspace/session/agents/main/backup.jsonl")
        for path in [main, child, backup] {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wire([request(), usage()]).write(to: path)
        }
        let scanner = KimiUsageScanner(environment: FakeEnvironment(["KIMI_CODE_HOME": root.path]), homeDirectory: root)
        let first = try await scanner.scan(now: now)
        let cached = try await scanner.scan(now: now)
        XCTAssertEqual(first?.series.daily.first?.totalTokens, 380)
        XCTAssertEqual(cached?.series.daily, first?.series.daily)

        try wire([request(), usage(), usage()]).write(to: main)
        let appended = try await scanner.scan(now: now)
        XCTAssertEqual(appended?.series.daily.first?.totalTokens, 570)
    }

    func testMissingStoreIsAbsentButUnreadableStoreThrows() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let scanner = KimiUsageScanner(environment: FakeEnvironment([:]), homeDirectory: root)
        let absent = try await scanner.scan(now: now)
        XCTAssertNil(absent)

        try FileManager.default.createDirectory(at: root.appendingPathComponent(".kimi-code"), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: root.appendingPathComponent(".kimi-code/sessions"))
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("existing unreadable history must fail")
        } catch {
            XCTAssertEqual((error as? KimiHistoryError)?.errorCategory, .storage)
        }
    }

    func testConfiguredTildeUsesInjectedHome() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("custom/sessions/workspace/session/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wire([request(), usage()]).write(to: path)
        let scanner = KimiUsageScanner(environment: FakeEnvironment(["KIMI_CODE_HOME": "~/custom"]), homeDirectory: root)

        let result = try await scanner.scan(now: now)

        XCTAssertEqual(result?.series.daily.first?.totalTokens, 190)
    }

    private var epochMilliseconds: Int { Int(now.timeIntervalSince1970 * 1_000) }

    private func request(model: String = "k3", alias: String = "kimi-code/k3") -> [String: Any] {
        ["type": "llm.request", "agentId": "main", "kind": "loop", "provider": "openai", "model": model, "modelAlias": alias]
    }

    private func usage(alias: String = "kimi-code/k3", scope: String = "turn") -> [String: Any] {
        ["type": "usage.record", "agentId": "main", "model": alias, "usageScope": scope,
         "time": epochMilliseconds,
         "usage": ["inputOther": 100, "output": 20, "inputCacheRead": 30, "inputCacheCreation": 40]]
    }

    private func wire(_ rows: [[String: Any]], version: String = "1.5") throws -> Data {
        let records = [["type": "metadata", "protocol_version": version, "created_at": epochMilliseconds]] + rows
        var data = Data()
        for row in records {
            data.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]))
            data.append(0x0A)
        }
        return data
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
