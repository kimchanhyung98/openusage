import XCTest
@testable import OpenUsage

final class OpenCodeForkUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00Z")!

    func testForkHistoryDoesNotIncreaseSpendTokensOrGoWindows() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("original", secondsAgo: 7200)
        try db.session("fork", secondsAgo: 600)
        try db.message("source", session: "original")
        try db.message("copy", session: "fork")
        let scan = try await db.scan()
        assertTotals(scan, cost: 1.5, tokens: 1200)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 1.5)
        XCTAssertEqual(scan.goWindows?.weeklySpend, 1.5)
        XCTAssertEqual(scan.goWindows?.monthlySpend, 1.5)
        XCTAssertEqual(try db.sqlite.queryValue(path: db.path, sql: "SELECT COUNT(*) FROM message;"), "2")
    }

    func testNewForkRequestsAndZenUsageRemainIncluded() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("original", secondsAgo: 7200)
        try db.session("fork", secondsAgo: 600)
        try db.message("source", session: "original")
        try db.message("copy", session: "fork")
        try db.message("new-go", session: "fork", secondsAgo: 300)
        try db.message("new-zen", session: "fork", secondsAgo: 200, provider: "opencode")
        let scan = try await db.scan()
        assertTotals(scan, cost: 4.5, tokens: 3600)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 3)
    }

    func testForkBeforeCompletionDoesNotDuplicateRecordedUsage() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("original", secondsAgo: 7200)
        try db.session("fork", secondsAgo: 600)
        try db.message("source", session: "original")
        try db.message("copy", session: "fork", completed: false)
        let scan = try await db.scan()
        assertTotals(scan, cost: 1.5, tokens: 1200)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 1.5)
    }

    func testTerminalErrorAfterForkDoesNotDuplicateTheSameUsage() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("original", secondsAgo: 7200)
        try db.session("fork", secondsAgo: 600)
        try db.message("source", session: "original")
        try db.message("copy", session: "fork", completed: false)
        try db.sqlite.execute(path: db.path, sql: """
            UPDATE message SET data = json_set(data, '$.finish', 'error',
                '$.error', json('{"message":"stream failed"}')) WHERE id = 'source';
            """)
        assertTotals(try await db.scan(), cost: 1.5, tokens: 1200)
    }

    func testCopiesBeforeAndAfterCompletionKeepOneUsageWithoutTheSource() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("fork", secondsAgo: 600)
        try db.session("nested-fork", secondsAgo: 300)
        try db.message("copy", session: "fork", completed: false)
        try db.message("nested-copy", session: "nested-fork")
        assertTotals(try await db.scan(), cost: 1.5, tokens: 1200)
    }

    func testIdenticalIndependentRequestsAreNotDeduplicated() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("first", secondsAgo: 7200)
        try db.session("second", secondsAgo: 7200)
        try db.session("fork", secondsAgo: 600)
        try db.message("first-request", session: "first")
        try db.message("second-request", session: "second")
        try db.message("copy", session: "fork")
        let scan = try await db.scan()
        assertTotals(scan, cost: 3, tokens: 2400)
    }

    func testNestedCopiesKeepOneUsageAfterSourceDeletion() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("fork", secondsAgo: 600)
        try db.session("nested-fork", secondsAgo: 300)
        try db.message("copy", session: "fork")
        try db.message("nested-copy", session: "nested-fork")
        let scan = try await db.scan()
        assertTotals(scan, cost: 1.5, tokens: 1200)
    }

    func testCopiesInDifferentProjectsRemainSeparate() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("fork", secondsAgo: 600)
        try db.session("other-fork", secondsAgo: 600, project: "other")
        try db.message("copy", session: "fork")
        try db.message("other-copy", session: "other-fork")
        let scan = try await db.scan()
        assertTotals(scan, cost: 3, tokens: 2400)
    }

    func testIdenticalMessagesKeepTheirMultiplicityAcrossForksAndSourceDeletion() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("original", secondsAgo: 7200)
        try db.session("fork", secondsAgo: 600)
        try db.session("partial-fork", secondsAgo: 300)
        try db.message("source-a", session: "original")
        try db.message("source-b", session: "original")
        try db.message("copy-a", session: "fork", completed: false)
        try db.message("copy-b", session: "fork")
        try db.message("partial-copy", session: "partial-fork")
        assertTotals(try await db.scan(), cost: 3, tokens: 2400)

        try db.sqlite.execute(path: db.path, sql: "DELETE FROM message WHERE id = 'source-a';")
        assertTotals(try await db.scan(), cost: 3, tokens: 2400)

        try db.sqlite.execute(path: db.path, sql: "DELETE FROM message WHERE session_id = 'original';")
        try db.sqlite.execute(path: db.path, sql: "DELETE FROM session WHERE id = 'original';")
        let scan = try await db.scan()
        assertTotals(scan, cost: 3, tokens: 2400)
        XCTAssertEqual(scan.goWindows?.sessionSpend, 3)
        XCTAssertEqual(scan.goWindows?.weeklySpend, 3)
        XCTAssertEqual(scan.goWindows?.monthlySpend, 3)
    }

    func testEqualCostAndTimeDoNotMergeDifferentUsage() async throws {
        let db = try ForkDatabase(now: now)
        try db.session("fork", secondsAgo: 600)
        try db.message("copy-a", session: "fork")
        try db.message("copy-b", session: "fork", tokens: 2000)
        let scan = try await db.scan()
        assertTotals(scan, cost: 3, tokens: 3200)
    }

    private func assertTotals(
        _ scan: OpenCodeUsageScan, cost: Double, tokens: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), cost,
                       accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }, tokens, file: file, line: line)
    }
}

private final class ForkDatabase {
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
            CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL, time_created INTEGER NOT NULL);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, data TEXT NOT NULL);
            """)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func session(_ id: String, secondsAgo: Double, project: String = "project") throws {
        try sqlite.execute(path: path, sql: "INSERT INTO session VALUES (?, ?, ?);", bindings: [
            id, project, String(milliseconds(secondsAgo: secondsAgo))
        ])
    }

    func message(
        _ id: String, session: String, secondsAgo: Double = 3600,
        provider: String = "opencode-go", tokens: Int = 1200, completed: Bool = true
    ) throws {
        let timestamp = milliseconds(secondsAgo: secondsAgo)
        var time = ["created": timestamp]
        if completed { time["completed"] = timestamp + 100 }
        let data = try JSONSerialization.data(withJSONObject: [
            "role": "assistant", "parentID": "parent-" + id,
            "time": time, "finish": "stop",
            "cost": 1.5, "tokens": ["total": tokens], "modelID": "glm-5.2", "providerID": provider
        ], options: [.sortedKeys])
        try sqlite.execute(path: path, sql: "INSERT INTO message VALUES (?, ?, ?, ?);", bindings: [
            id, session, String(timestamp), String(decoding: data, as: UTF8.self)
        ])
    }

    func scan() async throws -> OpenCodeUsageScan {
        let databasePath = path
        let scan = try await OpenCodeUsageScanner(databasePaths: { [databasePath] }).scan(now: now)
        return try XCTUnwrap(scan)
    }

    private func milliseconds(secondsAgo: Double) -> Int {
        Int(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000)
    }
}
