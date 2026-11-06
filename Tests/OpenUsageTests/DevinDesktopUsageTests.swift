import XCTest
@testable import OpenUsage

final class DevinDesktopUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-11-01T03:00:00Z")!

    func testExternalAndMissingProviderRemainUnattributed() throws {
        let providers: [String?] = [nil, "claude", "codex", "junie", "custom-agent", "devin-cloud"]
        for provider in providers {
            var event: [String: Any] = ["notification": [
                "sessionUpdate": "usage_update",
                "metadata": [
                    "request_id": "r1", "created_at": "2026-11-01T01:00:00Z",
                    "generation_model": "claude-sonnet-4-6",
                    "metrics": ["input_tokens": 100, "output_tokens": 10, "cache_read_tokens": 20]
                ]
            ]]
            if let provider { event["providerId"] = provider }
            let records = try DevinDesktopParser.parse(JSONSerialization.data(withJSONObject: event), path: "/fixture/session.ndjson")
            let record = try XCTUnwrap(records.first)
            XCTAssertNil(record.providerID)
            XCTAssertEqual(record.upstreamProvider, provider)
            XCTAssertEqual(record.tokens?.input, 100)
            XCTAssertEqual(record.tokens?.cacheRead, 20)
            XCTAssertEqual(record.totalTokens, 0)
            XCTAssertNil(record.responseID)
            XCTAssertTrue(record.issues.contains(.unresolvedMirror))
            let scan = UsageRecordFixture.history(records: records, providerID: "devin", since: .distantPast, pricing: .empty)
            XCTAssertTrue(scan.series.daily.isEmpty)
            XCTAssertNil(scan.metadataWarning)
        }
    }

    func testContextAndReplayedObservationsDoNotCreateUsageTotals() throws {
        let rows = """
        {"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","used":8000,"size":200000,"cost":{"amount":0.25,"currency":"USD"}}}
        {"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","_meta":{"cognition.ai/timestamp":"2026-11-01T01:00:00Z","cognition.ai/inputTokens":100,"cognition.ai/cachedReadTokens":200,"cognition.ai/outputTokens":10}}}
        {"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","_meta":{"cognition.ai/timestamp":1793494800000,"cognition.ai/inputTokens":100,"cognition.ai/cachedReadTokens":200,"cognition.ai/outputTokens":10,"cognition.ai/subagent_context":{"agentId":"child"}}}}
        """
        let records = try DevinDesktopParser.parse(Data(rows.utf8), path: "/fixture/session.ndjson")
        XCTAssertEqual(records.count, 3)
        XCTAssertNil(records[0].tokens)
        XCTAssertNil(records[0].recordedCostUSD)
        XCTAssertEqual(records[1].tokens?.input, 100)
        XCTAssertEqual(records[1].tokens?.cacheRead, 200)
        XCTAssertEqual(records[2].tokens?.output, 10)
        XCTAssertEqual(records[1].timestamp, OpenUsageISO8601.date(from: "2026-11-01T01:00:00Z"))
        XCTAssertEqual(records[2].timestamp, records[1].timestamp)
        XCTAssertTrue(records.allSatisfy { $0.totalTokens == 0 && $0.issues == [.unresolvedMirror] })
        XCTAssertEqual(UsageRecordDeduplicator.records(records).count, 3)
        let scan = UsageRecordFixture.history(records: records, providerID: "devin", since: .distantPast, pricing: .empty)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertNotNil(scan.metadataWarning)
    }

    func testUnverifiedRequestUpdatesKeepObservationsWithoutResponseIdentity() throws {
        let rows = """
        {"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","metadata":{"request_id":"same","created_at":"2026-11-01T01:00:00Z","metrics":{"input_tokens":100,"output_tokens":10}}}}
        {"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","metadata":{"request_id":"same","created_at":"2026-11-01T01:00:00Z","metrics":{"input_tokens":1000,"output_tokens":20}}}}
        """
        let records = try DevinDesktopParser.parse(Data(rows.utf8), path: "/fixture/session.ndjson")
        XCTAssertEqual(UsageRecordDeduplicator.records(records).count, 2)
        XCTAssertEqual(records.compactMap { $0.tokens?.input }, [100, 1000])
        XCTAssertTrue(records.allSatisfy { $0.responseID == nil && $0.totalTokens == 0 })
        XCTAssertTrue(records.allSatisfy { $0.issues.contains(.unresolvedMirror) })
    }

    func testExternalOnlyDesktopDoesNotConfirmEmptyDevinHistory() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(
            #"{"providerId":"claude","notification":{"sessionUpdate":"usage_update","metadata":{"request_id":"r1","created_at":"2026-11-01T01:00:00Z","metrics":{"input_tokens":100,"output_tokens":10}}}}"#,
            to: home.appendingPathComponent("Library/Application Support/Devin/User/acp-events/external.ndjson")
        )
        let scanner = DevinUsageScanner(environment: FakeEnvironment([:]), homeDirectory: home)
        let scan = try await scanner.scan(now: now, pricing: .empty)
        XCTAssertNil(scan)
    }

    func testKnownDevinContextIsIncompleteInsteadOfConfirmedEmptyHistory() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(
            #"{"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","used":8000,"size":200000}}"#,
            to: home.appendingPathComponent("Library/Application Support/Devin/User/acp-events/local.ndjson")
        )
        let scanner = DevinUsageScanner(environment: FakeEnvironment([:]), homeDirectory: home)
        let scan = try await scanner.scan(now: now, pricing: .empty)
        XCTAssertTrue(scan?.series.daily.isEmpty == true)
        XCTAssertEqual(scan?.invalidRows, 1)
        XCTAssertFalse(scan?.warnings.isEmpty == true)
    }

    func testMalformedMiddleLineKeepsDesktopObservations() throws {
        let row = #"{"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","used":8000}}"#
        let data = Data((row + "\n{" + "\n" + row).utf8)
        let records = try DevinDesktopParser.parse(data, path: "/fixture/session.ndjson")
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.filter { $0.kind == "invalid-line" && $0.issues.contains(.invalidMetadata) }.count, 1)
        XCTAssertEqual(records.filter { $0.issues.contains(.unresolvedMirror) }.count, 2)
    }

    func testSameFilenameInDifferentDirectoriesKeepsBothDesktopObservations() throws {
        let row = #"{"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","used":8000}}"#
        let first = try DevinDesktopParser.parse(Data(row.utf8), path: "/fixture/one/session.ndjson")
        let second = try DevinDesktopParser.parse(Data(row.utf8), path: "/fixture/two/session.ndjson")
        XCTAssertNotEqual(first.first?.sessionID, second.first?.sessionID)
        XCTAssertEqual(UsageRecordDeduplicator.records(first + second).count, 2)
    }

    func testLatestMessageCacheDoesNotClaimDevinHistory() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(
            Data(), to: home.appendingPathComponent("Library/Application Support/Devin/User/acp-messages/session.db")
        )
        let scanner = DevinUsageScanner(environment: FakeEnvironment([:]), homeDirectory: home)
        let scan = try await scanner.scan(now: now, pricing: .empty)
        XCTAssertNil(scan)
    }
}
