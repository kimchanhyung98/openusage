import SQLite3
import XCTest
@testable import OpenUsage

final class OpenCodeUsageSQLTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00Z")!

    func testMissingTotalIncludesEveryDisjointTokenComponent() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        try db.message("components", tokens: [
            "input": 100, "output": 20, "reasoning": 10, "cache": ["read": 30, "write": 40]
        ])
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.logScan.rejectedNumericRows, 0)
    }

    func testRecordedTotalIsNotAddedToTokenComponents() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        try db.message("total", tokens: [
            "total": 200, "input": 100, "output": 20, "reasoning": 10, "cache": ["read": 30, "write": 40]
        ])
        try db.message("zero", tokens: ["total": 0], cost: 0)
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.logScan.rejectedNumericRows, 0)
    }

    func testEveryStepIsCountedWithoutAddingTheMessageAggregate() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        try db.message("multi-step", tokens: ["total": 300], cost: 3)
        try db.step("first", message: "multi-step", tokens: [
            "input": 100, "output": 20, "reasoning": 10, "cache": ["read": 30, "write": 40]
        ], cost: 1)
        try db.step("last", message: "multi-step", tokens: ["total": 300], cost: 2)
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 500)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 3)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 3)
    }

    func testForkStepCopiesAreExcludedWhileSubagentUsageRemains() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        try db.session("fork", secondsAgo: 600)
        try db.session("child", secondsAgo: 300, parent: "original")
        try db.message("source", tokens: ["total": 300], cost: 3)
        try db.message("copy", session: "fork", tokens: ["total": 300], cost: 3)
        for (message, session) in [("source", "original"), ("copy", "fork")] {
            try db.step(message + "-first", message: message, session: session, tokens: ["total": 200], cost: 1)
            try db.step(message + "-last", message: message, session: session, tokens: ["total": 300], cost: 2)
        }
        try db.message("child-request", session: "child", secondsAgo: 100, tokens: ["total": 50], cost: 0.5)
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 550)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 3.5)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 3.5)
    }

    func testInvalidTotalsAndComponentsWarnWhileValidRowsRemain() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        let invalid: [Any] = [true, -5, 1.5, "invalid", NSNull(), 1e19]
        for (index, value) in invalid.enumerated() {
            try db.message("invalid-\(index)", tokens: ["total": value])
        }
        try db.message("invalid-component", tokens: ["total": 10, "reasoning": -1])
        try db.message("valid", tokens: ["total": 100])
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.logScan.rejectedNumericRows, 7)
        XCTAssertNotNil(scan.logScan.numericWarning)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 1)
    }

    func testInvalidStepDoesNotFallBackToMessageAggregate() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        try db.message("invalid-step", tokens: ["total": 100], cost: 9)
        try db.step("invalid", message: "invalid-step", tokens: ["total": true], cost: 9)
        try db.message("valid", tokens: ["total": 50], cost: 1)
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 50)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.logScan.rejectedNumericRows, 1)
        XCTAssertNotNil(scan.logScan.numericWarning)
    }

    func testTokenOverflowAlsoExcludesTheRejectedCostFromGoMeters() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        try db.message("large", tokens: ["total": Int.max])
        try db.message("extra", tokens: ["total": 1])
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.rejectedNumericRows, 1)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 1)
    }

    func testCommittedWALUsageIsVisibleWithoutCheckpointing() async throws {
        let db = try OpenCodeSQLFixture(now: now)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.path, &writer), SQLITE_OK)
        let handle = try XCTUnwrap(writer)
        defer { sqlite3_close(handle) }
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;", nil, nil, nil), SQLITE_OK)
        try db.message("wal", tokens: ["total": 100])
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path + "-wal"))
        let scan = try await db.scan()
        XCTAssertEqual(scan.logScan.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(scan.logScan.series.daily.first?.costUSD, 1)
    }
}

private final class OpenCodeSQLFixture {
    let directory: URL
    let path: String
    let now: Date
    let sqlite = SQLiteCLIAccessor()

    init(now: Date) throws {
        self.now = now
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        path = directory.appendingPathComponent("opencode.db").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sqlite.execute(path: path, sql: """
            CREATE TABLE session (
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL, time_created INTEGER NOT NULL, parent_id TEXT
            );
            CREATE TABLE message (
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL
            );
            CREATE TABLE part (
                id TEXT PRIMARY KEY, message_id TEXT NOT NULL, session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL, data TEXT NOT NULL
            );
            """)
        try session("original", secondsAgo: 7200)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func session(_ id: String, secondsAgo: Double, parent: String = "") throws {
        try sqlite.execute(path: path, sql: "INSERT INTO session VALUES (?, ?, ?, ?);", bindings: [
            id, "project", String(milliseconds(secondsAgo: secondsAgo)), parent
        ])
    }

    func message(
        _ id: String, session: String = "original", secondsAgo: Double = 3600,
        tokens: [String: Any], cost: Double = 1
    ) throws {
        let timestamp = milliseconds(secondsAgo: secondsAgo)
        let data = try JSONSerialization.data(withJSONObject: [
            "role": "assistant", "parentID": "parent-" + id,
            "time": ["created": timestamp], "cost": cost, "tokens": tokens,
            "modelID": "glm-5.2", "providerID": "opencode-go"
        ], options: [.sortedKeys])
        try sqlite.execute(path: path, sql: "INSERT INTO message VALUES (?, ?, ?, ?);", bindings: [
            id, session, String(timestamp), String(decoding: data, as: UTF8.self)
        ])
    }

    func step(
        _ id: String, message: String, session: String = "original", tokens: [String: Any], cost: Double
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "step-finish", "reason": "stop", "tokens": tokens, "cost": cost
        ], options: [.sortedKeys])
        try sqlite.execute(path: path, sql: "INSERT INTO part VALUES (?, ?, ?, ?, ?);", bindings: [
            id, message, session, String(milliseconds(secondsAgo: 3500)), String(decoding: data, as: UTF8.self)
        ])
    }

    func scan() async throws -> OpenCodeUsageScan {
        let databasePath = path
        let result = try await OpenCodeUsageScanner(databasePaths: { [databasePath] }).scan(now: now)
        return try XCTUnwrap(result)
    }

    private func milliseconds(secondsAgo: Double) -> Int {
        Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000)
    }
}
