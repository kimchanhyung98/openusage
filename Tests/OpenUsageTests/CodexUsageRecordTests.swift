import XCTest
@testable import OpenUsage

final class CodexUsageRecordTests: XCTestCase {
    private let timestamp = "2026-11-02T01:00:00Z"

    func testResponseRecordReplacesLegacySnapshotInEitherOrder() throws {
        let record = record(response: "response-1", input: 1_000)
        let legacy = count(input: 1_000, totalInput: 1_000)
        for lines in [[record, legacy], [legacy, record]] {
            let events = parse([context()] + lines)
            XCTAssertEqual(events.map(\.input), [1_000])
            XCTAssertEqual(events.first?.usageRecordID, "session-1:response-1")
        }
    }

    func testCompactionConsumptionSurvivesContextRecalculation() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            record(response: "compact", input: 500), count(input: 0, totalInput: 1_000)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500])
    }

    func testIncompleteRecordDoesNotRepeatThePreviousResponse() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            record(response: "incomplete", input: 500), count(input: 1_000, totalInput: 1_500)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500])
    }

    func testIncompleteWithoutResponseIDUsesLegacyCumulativeDelta() {
        let events = parse([context(), count(input: 1_000, totalInput: 1_000), count(input: 1_000, totalInput: 1_500)])
        XCTAssertEqual(events.map(\.input), [1_000, 500])
    }

    func testIncompleteWithoutResponseIDSurvivesRecordedResponseInSameTurn() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            count(input: 1_000, totalInput: 1_500),
            record(response: "recovered", input: 200), count(input: 200, totalInput: 1_700)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500, 200])
        XCTAssertFalse(events.contains { $0.invalidMetadata })
    }

    func testIncompleteBeforeFirstRecordRemainsInSameTurn() {
        let events = parse([
            context(), count(input: 500, totalInput: 500),
            record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_500)
        ])
        XCTAssertEqual(events.map(\.input), [500, 1_000])
    }

    func testSeveralRecordsShareOneCumulativeIncrease() {
        let events = parse([
            context(), record(response: "one", input: 500), record(response: "two", input: 300),
            count(input: 800, totalInput: 800),
            count(input: 800, totalInput: 1_000)
        ])
        XCTAssertEqual(events.map(\.input), [500, 300, 200])
    }

    func testRemoteCompactionDoesNotConsumeAnEqualIncompleteIncrease() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            record(response: "compact", input: 500),
            line(type: "compacted", payload: ["compaction_response_id": "compact"]),
            count(input: 1_000, totalInput: 1_000),
            count(input: 1_000, totalInput: 1_500)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500, 500])
    }

    func testRemoteCompactionRecalculationCanDecreaseTheBaseline() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            record(response: "compact", input: 500),
            line(type: "compacted", payload: ["compaction_response_id": "compact"]),
            count(input: 0, totalInput: 200),
            count(input: 0, totalInput: 700)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500, 500])
    }

    func testLocalCompactionIsDeduplicatedBeforeInstallation() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            record(response: "compact", input: 500), count(input: 500, totalInput: 1_500),
            line(type: "compacted", payload: ["compaction_response_id": "compact"]),
            count(input: 500, totalInput: 1_500),
            count(input: 500, totalInput: 2_000)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500, 500])
    }

    func testFailedCompactionWithAmbiguousIncompleteUsageWarns() {
        for terminal in ["task_complete", "turn_aborted"] {
            let events = parse([
                context(), record(response: "failed-compact", input: 500),
                count(input: 500, totalInput: 500),
                line(type: "event_msg", payload: [
                    "type": terminal, "turn_id": "turn-1", "error": ["message": "compaction failed"]
                ])
            ])
            let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: TestPricing.bundled)
            XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 500)
            XCTAssertEqual(scan.rejectedMetadataRows, 1)
            XCTAssertNotNil(scan.metadataWarning)
        }
    }

    func testTerminalErrorDoesNotDiscardAnUnrecordedIncreaseAfterCompletedBoundary() {
        let events = parse([
            context(), record(response: "normal", input: 1_000), count(input: 1_000, totalInput: 1_000),
            count(input: 1_000, totalInput: 1_500),
            line(type: "event_msg", payload: [
                "type": "task_complete", "turn_id": "turn-1", "error": ["message": "incomplete"]
            ])
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500])
        XCTAssertFalse(events.contains { $0.invalidMetadata })
    }

    func testLegacyTurnsRemainWhenLaterTurnsUseRecords() {
        let events = parse([
            context(turn: "old"), count(input: 1_000, totalInput: 1_000),
            context(), record(response: "new", input: 500), count(input: 500, totalInput: 1_500),
            context(turn: "legacy-after"), count(input: 200, totalInput: 1_700)
        ])
        XCTAssertEqual(events.map(\.input), [1_000, 500, 200])
    }

    func testCopiedRecordIsDeduplicatedWithoutMergingDistinctResponses() {
        let first = parse([context(), record(response: "one", input: 500)])
        let copy = parse([context(), record(response: "one", input: 500, at: "2026-11-02T02:00:00Z")])
        let second = parse([context(), record(response: "two", input: 500)])
        let scan = CodexLogUsageScanner.aggregate(events: first + copy + second, since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 1_000)
    }

    func testForkReplayExcludesParentRecordsBeforeLiveTurn() {
        let created = OpenUsageISO8601.date(from: timestamp)!
        let events = parse([
            CodexLogFixture.forkSessionMeta(timestamp: timestamp),
            context(turn: "parent"), record(response: "copied", input: 1_000, turn: "parent"),
            CodexLogFixture.taskStarted(timestamp: timestamp, startedAt: Int(created.timeIntervalSince1970)),
            context(), record(response: "child", input: 500)
        ])
        XCTAssertEqual(events.map(\.input), [500])
    }

    func testRecordUsesItsTurnModelAndTierWhenAnotherTurnStarts() {
        let events = parse([
            context(turn: "first"),
            CodexLogFixture.threadSettingsApplied(timestamp: timestamp, serviceTier: "priority", model: "gpt-5.2"),
            context(turn: "second", model: "gpt-5.4"),
            CodexLogFixture.threadSettingsApplied(timestamp: timestamp, serviceTier: "default", model: "gpt-5.4"),
            record(response: "first", input: 100, turn: "first"),
            record(response: "second", input: 200, turn: "second")
        ])
        XCTAssertEqual(events.map(\.model), ["gpt-5.2", "gpt-5.4"])
        XCTAssertEqual(events.map(\.isFast), [true, false])
    }

    func testMalformedRecordCannotFallBackToAConflictingLegacyAmount() {
        let invalid = record(response: "bad", input: -1)
        let events = parse([context(), invalid, count(input: 1_000, totalInput: 1_000)])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.invalidNumericValues, true)
    }

    private func context(turn: String = "turn-1", model: String = "gpt-5.2") -> String {
        line(type: "turn_context", payload: ["turn_id": turn, "model": model])
    }

    private func record(response: String, input: Int, turn: String = "turn-1", at: String? = nil) -> String {
        let usage = CodexLogFixture.usage(input: input, cached: 0, output: 0)
        return line(type: "token_usage_record", payload: [
            "thread_id": "thread-1", "turn_id": turn, "session_id": "session-1", "root_turn_id": turn,
            "response_id": response, "usage": usage, "turn_token_usage": usage, "thread_token_usage": usage
        ], at: at)
    }

    private func count(input: Int, totalInput: Int) -> String {
        CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: input, output: 0),
                                   totals: CodexLogFixture.usage(input: totalInput, output: 0))
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
