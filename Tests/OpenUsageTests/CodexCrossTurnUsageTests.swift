import XCTest
@testable import OpenUsage

final class CodexCrossTurnUsageTests: XCTestCase {
    private let timestamp = "2026-11-02T01:00:00Z"
    private let nextTimestamp = "2026-11-02T01:01:00Z"

    func testPendingRecordsMatchContinuousDeltasWithoutChangingTheirModel() {
        for currentInput in [0, 200] {
            for hasLast in [true, false] {
                var lines = [context("first"), count(last: 100, total: 100), record("first", input: 500),
                             context("second", model: "gpt-5.4")]
                if currentInput > 0 { lines.append(record("second", input: currentInput, at: nextTimestamp)) }
                lines.append(count(last: hasLast ? (currentInput > 0 ? currentInput : 500) : nil,
                                   total: 600 + currentInput, model: "gpt-5.4", at: nextTimestamp))
                let events = parse(lines)
                XCTAssertEqual(events.map(\.input), currentInput > 0 ? [100, 500, 200] : [100, 500])
                XCTAssertEqual(events.first { $0.usageRecordID == "session:first" }?.model, "gpt-5.2")
                XCTAssertFalse(events.contains { $0.invalidMetadata || $0.invalidNumericValues })
            }
        }
    }

    func testEmptyLastOnlyNotificationPreservesPendingCrossTurnRecords() {
        let events = parse([
            context("first"), count(last: 100, total: 100), record("first", input: 500),
            count(last: 0, total: nil), context("second", model: "gpt-5.4"),
            record("second", input: 200, at: nextTimestamp), count(last: 200, total: 800, at: nextTimestamp)
        ])
        XCTAssertEqual(events.map(\.input), [100, 500, 200])
        XCTAssertEqual(events.map(\.model), ["gpt-5.2", "gpt-5.2", "gpt-5.4"])
        XCTAssertFalse(events.contains { $0.invalidMetadata || $0.invalidNumericValues })
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 800)
    }

    func testAbortedPendingRecordKeepsLedgersAndWarnsAboutAmbiguousDelta() {
        for terminal in ["turn_aborted", "task_complete"] {
            for hasError in [false, true] where terminal == "turn_aborted" || hasError {
                var payload: [String: Any] = ["type": terminal, "turn_id": "first", "reason": "interrupted"]
                if hasError { payload["error"] = ["message": "response failed"] }
                let events = parse([
                    context("first"), count(last: 100, total: 100), record("first", input: 500),
                    line(type: "event_msg", payload: payload), context("second"),
                    record("second", input: 200, at: nextTimestamp), count(last: 200, total: 800, at: nextTimestamp)
                ])
                let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
                XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 800)
                XCTAssertEqual(scan.rejectedMetadataRows, 1)
                XCTAssertNotNil(scan.metadataWarning)
            }
        }
    }

    func testLastOnlyAndResetCountsDoNotConsumePriorTurnRecords() {
        let suffixes = [
            [count(last: 500, total: nil)],
            [count(last: 500, total: 500)],
            [count(last: 0, total: nil), count(last: 500, total: 500)]
        ]
        for suffix in suffixes {
            let events = parse([context("first"), count(last: 1_000, total: 1_000),
                                record("first", input: 500),
                                line(type: "event_msg", payload: ["type": "turn_aborted", "turn_id": "first"]),
                                context("second")] + suffix)
            XCTAssertEqual(events.map(\.input), [1_000, 500, 500])
            XCTAssertFalse(events.contains { $0.invalidMetadata || $0.invalidNumericValues })
        }
    }

    func testRestoringBaselineAfterLastOnlyUsageDoesNotConsumePriorRecords() {
        let events = parse([
            context("first"), count(last: 100, total: 100), count(last: 20, total: nil),
            record("first", input: 500), context("second"), count(last: 500, total: 1_120)
        ])
        XCTAssertEqual(events.map(\.input), [100, 20, 500, 500])
        XCTAssertFalse(events.contains { $0.invalidMetadata || $0.invalidNumericValues })
    }

    func testInstalledRemoteCompactionDoesNotConsumeTheNextTurnDelta() {
        let events = parse([
            context("first"), count(last: 100, total: 100), record("first", input: 500),
            line(type: "compacted", payload: ["compaction_response_id": "first"]),
            line(type: "event_msg", payload: ["type": "turn_aborted", "turn_id": "first"]),
            context("second"), count(last: 500, total: 600)
        ])
        XCTAssertEqual(events.map(\.input), [100, 500, 500])
        XCTAssertFalse(events.contains { $0.invalidMetadata || $0.invalidNumericValues })
    }

    func testMalformedPriorTurnRecordRejectsOnlyTheContinuousDeltaInterval() {
        let events = parse([
            context("first"), count(last: 100, total: 100), record("first", input: -1),
            context("second"), record("second", input: 200), count(last: 200, total: 800),
            count(last: 300, total: 1_100)
        ])
        XCTAssertEqual(events.filter { !$0.invalidNumericValues }.map(\.input), [100, 200, 300])
        XCTAssertEqual(events.filter(\.invalidNumericValues).count, 1)
        let independent = parse([context("first"), count(last: 100, total: 100), record("first", input: -1),
                                 context("second"), count(last: 200, total: nil)])
        XCTAssertEqual(independent.filter { !$0.invalidNumericValues }.map(\.input), [100, 200])
    }

    private func context(_ turn: String, model: String = "gpt-5.2") -> String {
        line(type: "turn_context", payload: ["turn_id": turn, "model": model])
    }

    private func record(_ turn: String, input: Int, at: String? = nil) -> String {
        line(type: "token_usage_record", payload: [
            "session_id": "session", "turn_id": turn, "response_id": turn,
            "usage": CodexLogFixture.usage(input: input, output: 0)
        ], at: at)
    }

    private func count(last: Int?, total: Int?, model: String? = nil, at: String? = nil) -> String {
        CodexLogFixture.tokenCount(timestamp: at ?? timestamp,
                                  last: last.map { CodexLogFixture.usage(input: $0, output: 0) },
                                  totals: total.map { CodexLogFixture.usage(input: $0, output: 0) }, model: model)
    }

    private func line(type: String, payload: [String: Any], at: String? = nil) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [
            "timestamp": at ?? timestamp, "type": type, "payload": payload
        ]), as: UTF8.self)
    }

    private func parse(_ lines: [String]) -> [CodexLogUsageScanner.Event] {
        CodexLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
    }
}
