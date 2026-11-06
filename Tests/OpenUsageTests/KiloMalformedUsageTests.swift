import XCTest
@testable import OpenUsage

@MainActor
final class KiloMalformedUsageTests: XCTestCase {
    func testMalformedDatabaseJSONPreservesOtherRequestsAndDiagnostics() async throws {
        let database = try KiloReviewDatabase()
        try database.step("good-step", cost: 0.2)
        try database.step("bad-part")
        try database.message("bad-message")
        try database.assistant("bad-v2", seq: 1, cost: 0.1)
        try database.assistant("good-v2", seq: 2, cost: 0.3)
        try database.execute("""
        UPDATE part SET data='{' WHERE message_id='bad-part';
        UPDATE message SET data='{' WHERE id='bad-message';
        UPDATE session_message SET data='{' WHERE id='bad-v2';
        """)

        let result = try await collect(database)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.sources.first?.completedStores, 1)
        let invalid = result.records.filter { $0.issues.contains(.invalidMetadata) }
        XCTAssertEqual(Set(invalid.compactMap(\.id)), ["part-bad-part", "bad-message", "bad-v2"])
        XCTAssertTrue(invalid.allSatisfy { $0.filePath == database.file.resolvingSymlinksInPath().path && $0.timestamp != nil })
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 240)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.5, accuracy: 1e-9)
    }

    func testMalformedParentMessageDoesNotDiscardOtherRequests() async throws {
        let database = try KiloReviewDatabase()
        try database.step("bad-parent")
        try database.step("good")
        try database.execute("UPDATE message SET data='{' WHERE id='bad-parent'")

        let result = try await collect(database)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.filter { $0.issues.isEmpty }.map(\.id), ["part-good"])
        XCTAssertTrue(result.records.contains { $0.id == "part-bad-parent" && $0.issues.contains(.invalidMetadata) })
    }

    func testDatabaseSchemaFailureStillFailsTheStore() async throws {
        let database = try KiloReviewDatabase()
        try database.step("good")
        try database.execute("DROP TABLE part; CREATE TABLE part(id TEXT)")

        let result = try await collect(database)
        XCTAssertEqual(result.readFailureCount, 1)
        XCTAssertEqual(result.sources.first?.completedStores, 0)
        XCTAssertTrue(result.records.isEmpty)
    }

    func testLegacyMalformedInnerJSONKeepsBothValidNeighbors() throws {
        let valid = #"{"tokensIn":100,"tokensOut":20,"cost":0.2,"modelInfo":{"id":"tiered-model"}}"#
        let messages: [[String: Any]] = [valid, "{", valid].enumerated().map { index, text in
            ["id": "row-\(index)", "type": "say", "say": "api_req_started", "ts": 1_793_494_800_000, "text": text]
        }
        let data = try JSONSerialization.data(withJSONObject: messages)
        let records = try KiloUsageParser.legacy(data, path: "/fixture/task/ui_messages.json")

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.filter { $0.issues.isEmpty }.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(records.compactMap(\.recordedCostUSD).reduce(0, +), 0.4, accuracy: 1e-9)
        let invalid = try XCTUnwrap(records.first { $0.id == "row-1" })
        XCTAssertEqual(invalid.issues, [.invalidMetadata])
        XCTAssertEqual(invalid.sessionID, "task")
        XCTAssertNotNil(invalid.timestamp)
        XCTAssertThrowsError(try KiloUsageParser.legacy(Data("[".utf8), path: "/fixture/task/ui_messages.json"))
    }

    func testCostOnlyDatabaseRequestsKeepCostWhileMessageRollupStaysUnresolved() async throws {
        let database = try KiloReviewDatabase()
        try database.step("step", cost: 0.2)
        try database.message("rollup", cost: 0.5)
        try database.assistant("v2", seq: 1, cost: 0.3)
        try database.execute("""
        UPDATE part SET data=json_remove(data,'$.tokens');
        UPDATE message SET data=json_remove(data,'$.tokens');
        UPDATE session_message SET data=json_remove(data,'$.tokens');
        """)

        let result = try await collect(database)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertTrue(result.records.allSatisfy { $0.totalTokens == 0 })
        XCTAssertEqual(result.records.first { $0.id == "rollup" }?.issues, [.unresolvedMirror])
        XCTAssertEqual(result.records.first { $0.id == "part-step" }?.recordedCostUSD, 0.2)
        XCTAssertEqual(result.records.first { $0.id == "v2" }?.recordedCostUSD, 0.3)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 0)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.5, accuracy: 1e-9)
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
    }

    func testPresentMalformedTokensAndCacheAreRejectedAcrossDatabaseFormats() async throws {
        for field in ["tokens", "tokens.cache"] {
            for malformed in ["null", "[]", "42", #""broken""#] {
                let database = try KiloReviewDatabase()
                try database.step("step")
                try database.message("rollup")
                try database.assistant("v2", seq: 1, cost: 0.1)
                for table in ["part", "message", "session_message"] {
                    try database.execute("UPDATE \(table) SET data=json_set(data,'$.\(field)',json('\(malformed)'))")
                }
                let result = try await collect(database)
                XCTAssertEqual(result.readFailureCount, 0, "\(field): \(malformed)")
                XCTAssertEqual(result.records.count, 3, "\(field): \(malformed)")
                XCTAssertTrue(result.records.allSatisfy { $0.issues.contains(.invalidNumbers) }, "\(field): \(malformed)")
                XCTAssertTrue(result.records.allSatisfy { $0.recordedCostUSD == 0.1 })
                let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
                XCTAssertTrue(scan.series.daily.isEmpty)
                XCTAssertEqual(scan.rejectedNumericRows, 2)
                XCTAssertEqual(scan.rejectedMetadataRows, 1)
            }
        }
    }

    func testAbsentCacheRetainsTokensAndMetadataOnlyRowsAreIgnored() async throws {
        let database = try KiloReviewDatabase()
        try database.step("step")
        try database.assistant("v2", seq: 1, cost: 0.1)
        try database.assistant("metadata", seq: 2, cost: nil)
        try database.execute("""
        UPDATE part SET data=json_remove(data,'$.tokens.cache');
        UPDATE session_message SET data=json_remove(data,'$.tokens.cache');
        UPDATE session_message SET data=json_remove(data,'$.tokens') WHERE id='metadata';
        """)

        let result = try await collect(database)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy { $0.issues.isEmpty && $0.totalTokens == 120 })
    }

    private func collect(_ database: KiloReviewDatabase) async throws -> UsageCollection {
        let collector = UsageSQLiteCollector(sourceID: "kilo", roots: [database.file], includeFile: { _ in true }, parse: KiloUsageParser.database)
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        return try XCTUnwrap(collected)
    }
}
