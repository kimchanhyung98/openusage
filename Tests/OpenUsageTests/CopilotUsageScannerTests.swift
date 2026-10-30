import Foundation
import SQLite3
import XCTest
@testable import OpenUsage

final class CopilotUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-10-30T16:00:00Z")!

    func testReadsCommittedWALUsageWithoutChangingDatabaseOrDoubleCountingTokenSubsets() async throws {
        let database = try CopilotScannerDatabase(wal: true)
        defer { database.remove() }
        try database.insert(date: "2026-10-30T15:00:00Z", model: "fixture-model", nanoAIU: "100000000000")
        try database.insert(
            date: "2026-10-30T15:01:00Z", model: "tiny-model",
            input: "10", output: "2", nanoAIU: "25000000"
        )
        let before = try database.contentFiles()
        XCTAssertGreaterThan(try XCTUnwrap(before["-wal"]).count, 0)

        let result = try await database.scanner.scan(now: now)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 132)
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.00025, accuracy: 1e-12)
        let models = scan.modelUsage?.daily.flatMap(\.models) ?? []
        XCTAssertEqual(models.first(where: { $0.model == "fixture-model" })?.totalTokens, 120)
        XCTAssertEqual(try XCTUnwrap(models.first(where: { $0.model == "tiny-model" })?.costUSD), 0.00025, accuracy: 1e-12)
        XCTAssertNil(scan.numericWarning)
        XCTAssertEqual(try database.contentFiles(), before)
        XCTAssertEqual(try database.scalar("SELECT value FROM unrelated_settings;"), "fixture-preserved")
    }

    func testRepeatedScansReplaceTheSameRequestRatherThanAccumulatingIt() async throws {
        let database = try CopilotScannerDatabase()
        defer { database.remove() }
        try database.insert(date: "2026-10-30T15:00:00Z", nanoAIU: "100000000000")
        let scanner = database.scanner
        let first = try await scanner.scan(now: now)
        let second = try await scanner.scan(now: now)
        XCTAssertEqual(first?.usageHistory, second?.usageHistory)

        try database.execute("UPDATE assistant_usage_events SET input_tokens = 200, total_nano_aiu = 200000000000;")
        let changed = try await scanner.scan(now: now)
        XCTAssertEqual(changed?.series.daily.reduce(0) { $0 + $1.totalTokens }, 220)
        XCTAssertEqual(changed?.series.daily.compactMap(\.costUSD).reduce(0, +), 2)
    }

    func testEmptyStoreIsAuthoritativeButAbsentStoreHasNoHistory() async throws {
        let database = try CopilotScannerDatabase()
        defer { database.remove() }
        let empty = try await database.scanner.scan(now: now)
        XCTAssertNotNil(empty?.usageHistory)
        XCTAssertEqual(empty?.series.daily, [])

        let absent = CopilotUsageScanner(databasePath: { nil })
        XCTAssertFalse(absent.hasLocalUsageStore())
        let missing = try await absent.scan(now: now)
        XCTAssertNil(missing)
    }

    func testDisappearedDatabaseIsNotCreatedByTheRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("missing.db").path
        let scanner = CopilotUsageScanner(databasePath: { path })

        await assertScanError(scanner, category: .storage)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testMissingUsageTableIsAnErrorNotAnEmptySuccessfulHistory() async throws {
        let database = try CopilotScannerDatabase()
        defer { database.remove() }
        try database.execute("DROP TABLE assistant_usage_events;")
        await assertScanError(database.scanner, category: .storage)
    }

    func testMalformedQueryPayloadCannotReplaceLastGoodHistory() async {
        for json in ["not-json", "{}", "[null]", "[[1,2]]"] {
            let scanner = CopilotUsageScanner(
                sqlite: CopilotScannerPayload(json: json), databasePath: { "/fixture/session-store.db" }
            )
            await assertScanError(scanner, category: .decoding)
        }
    }

    func testSQLiteUTCTimestampsUseTheRequestedLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let scan = try CopilotUsageScanner.aggregate(json: """
            [["2026-10-30 14:59:59","fixture-before-midnight",100,20,100000000000],
             ["2026-10-30 15:00:00","fixture-after-midnight",200,30,200000000000]]
            """, now: now, calendar: calendar)

        XCTAssertEqual(scan.series.daily, [
            DailyUsageEntry(date: "2026-10-31", totalTokens: 230, costUSD: 2),
            DailyUsageEntry(date: "2026-10-30", totalTokens: 120, costUSD: 1)
        ])
    }

    func testSQLWindowRetainsBoundaryAndReportsMalformedDatesWhileExcludingOldAndFutureUsage() async throws {
        let database = try CopilotScannerDatabase()
        defer { database.remove() }
        let calendar = Calendar.current
        let since = try XCTUnwrap(calendar.date(byAdding: .day, value: -30, to: calendar.startOfDay(for: now)))
        try database.insert(date: OpenUsageISO8601.string(from: since), input: "40", output: "10")
        try database.insert(date: OpenUsageISO8601.string(from: since.addingTimeInterval(-1)), input: "'bad-old-number'")
        try database.insert(date: OpenUsageISO8601.string(from: now.addingTimeInterval(-60)), input: "90", output: "10")
        try database.insert(date: OpenUsageISO8601.string(from: now.addingTimeInterval(1)), input: "9999")
        try database.insert(date: "invalid-date")
        try database.insert(date: nil)

        let result = try await database.scanner.scan(now: now)
        let scan = try XCTUnwrap(result)

        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 150)
        XCTAssertEqual(scan.rejectedNumericRows, 0)
        XCTAssertEqual(scan.rejectedMetadataRows, 2)
        XCTAssertNil(scan.numericWarning)
        XCTAssertNotNil(scan.metadataWarning)
        XCTAssertNotNil(scan.usageHistory)
    }

    func testInvalidMetadataIsSeparateFromNumericFailuresAndCannotClearHistory() throws {
        let scan = try CopilotUsageScanner.aggregate(json: """
            [["invalid-date","fixture-model",100,20,100000000000],
             ["2026-10-30T15:00:00Z",null,100,20,100000000000]]
            """, now: now)

        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.rejectedMetadataRows, 2)
        XCTAssertEqual(scan.rejectedNumericRows, 0)
        XCTAssertNotNil(scan.metadataWarning)
        XCTAssertNil(scan.numericWarning)
        XCTAssertNil(scan.usageHistory)

        let mixed = try CopilotUsageScanner.aggregate(json: """
            [["invalid-date","fixture-model",100,20,100000000000],
             ["2026-10-30T15:00:00Z","fixture-model",-1,20,100000000000],
             ["2026-10-30T15:00:00Z","fixture-model",100,20,100000000000]]
            """, now: now)
        XCTAssertEqual(mixed.rejectedMetadataRows, 1)
        XCTAssertEqual(mixed.rejectedNumericRows, 1)
        XCTAssertNotNil(mixed.metadataWarning)
        XCTAssertNotNil(mixed.numericWarning)
        XCTAssertEqual(mixed.usageHistory?.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(mixed.usageHistory?.series.daily.first?.costUSD, 1)
    }

    func testNullUsageFieldsDoNotBecomeZeroOrErasePriorHistory() async throws {
        let database = try CopilotScannerDatabase()
        defer { database.remove() }
        try database.insert(date: "2026-10-30T15:00:00Z", nanoAIU: "NULL")
        try database.insert(date: "2026-10-30T15:00:00Z", input: "NULL")
        try database.insert(date: "2026-10-30T15:00:00Z", output: "NULL")

        let result = try await database.scanner.scan(now: now)
        let scan = try XCTUnwrap(result)

        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unsupportedPricingRows, 1)
        XCTAssertEqual(scan.rejectedNumericRows, 2)
        XCTAssertNotNil(scan.pricingWarning)
        XCTAssertNil(scan.usageHistory)
    }

    func testInvalidOrMissingCountsAreExcludedInsteadOfFabricatingTokensOrCost() throws {
        let cases = [
            ["null", "20", "100"], ["100", "null", "100"],
            ["-1", "20", "100"], ["true", "20", "100"],
            ["1.5", "20", "100"], ["9223372036854775808", "20", "100"],
            ["\"9223372036854775807\"", "1", "100"],
            ["100", "20", "-1"], ["100", "20", "false"],
            ["100", "20", "0.5"]
        ]
        for counts in cases {
            let scan = try aggregateRow(counts.joined(separator: ","))
            XCTAssertTrue(scan.series.daily.isEmpty, "unexpected usage for \(counts)")
            XCTAssertEqual(scan.rejectedNumericRows, 1)
            XCTAssertNil(scan.usageHistory)
        }
    }

    func testNumericStringsAndRecordedZeroCostRemainValid() throws {
        let paid = try aggregateRow("\"100\",\"20\",\"100000000000\"")
        XCTAssertEqual(paid.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(paid.series.daily.first?.costUSD, 1)
        let zero = try aggregateRow("100,20,0")
        XCTAssertEqual(zero.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(zero.series.daily.first?.costUSD, 0)
        XCTAssertNotNil(zero.usageHistory)
    }

    func testCrossRequestOverflowKeepsValidRowsAndReportsTheRejectedRequest() throws {
        let scan = try CopilotUsageScanner.aggregate(json: """
            [["2026-10-30T15:00:00Z","fixture-large","9223372036854775806",0,100000000000],
             ["2026-10-30T15:01:00Z","fixture-overflow",2,0,200000000000]]
            """, now: now)

        XCTAssertEqual(scan.series.daily.first?.totalTokens, Int.max - 1)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 1)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
        XCTAssertNotNil(scan.numericWarning)
        XCTAssertNoThrow(try JSONEncoder().encode(scan.usageHistory))
    }

    func testExplicitCLIHomeDoesNotMixInTheDefaultStore() {
        let home = URL(fileURLWithPath: "/fixture/home", isDirectory: true)
        XCTAssertEqual(
            CopilotUsageScanner.resolvedDatabasePath(environment: [:], homeDirectory: home),
            "/fixture/home/.copilot/session-store.db"
        )
        XCTAssertEqual(
            CopilotUsageScanner.resolvedDatabasePath(environment: ["COPILOT_HOME": "/fixture/custom"], homeDirectory: home),
            "/fixture/custom/session-store.db"
        )
    }

    private func aggregateRow(_ counts: String) throws -> LogUsageScan {
        try CopilotUsageScanner.aggregate(
            json: "[[\"2026-10-30T15:00:00Z\",\"fixture-model\",\(counts)]]", now: now
        )
    }

    private func assertScanError(_ scanner: CopilotUsageScanner, category: ErrorCategory) async {
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected an explicit history read failure")
        } catch {
            XCTAssertEqual((error as? CopilotHistoryError)?.errorCategory, category)
        }
    }
}

private struct CopilotScannerPayload: SQLiteAccessing {
    let json: String
    func queryValue(path: String, sql: String) throws -> String? { json }
    func execute(path: String, sql: String) throws { throw CopilotHistoryError.databaseUnreadable }
}

private final class CopilotScannerDatabase {
    let directory: URL
    let path: String
    private var handle: OpaquePointer?

    init(wal: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        path = directory.appendingPathComponent("session-store.db").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard sqlite3_open(path, &handle) == SQLITE_OK else { throw CopilotHistoryError.databaseUnreadable }
        if wal { try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;") }
        try execute("""
            CREATE TABLE assistant_usage_events (
                id INTEGER PRIMARY KEY, session_id TEXT NOT NULL DEFAULT 'fixture-session',
                model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_tokens INTEGER DEFAULT 40, cache_write_tokens INTEGER DEFAULT 10,
                reasoning_tokens INTEGER DEFAULT 5, total_nano_aiu INTEGER,
                request_multiplier REAL DEFAULT 9, created_at TEXT DEFAULT (datetime('now'))
            );
            CREATE TABLE unrelated_settings (value TEXT);
            INSERT INTO unrelated_settings VALUES ('fixture-preserved');
            """)
    }

    deinit { remove() }

    func remove() {
        if let handle { sqlite3_close(handle) }
        handle = nil
        try? FileManager.default.removeItem(at: directory)
    }

    var scanner: CopilotUsageScanner {
        let databasePath = path
        return CopilotUsageScanner(databasePath: { databasePath })
    }

    func insert(
        date: String?, model: String = "fixture-model", input: String = "100",
        output: String = "20", nanoAIU: String = "1000000000"
    ) throws {
        let dateSQL = date.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" } ?? "NULL"
        try execute("""
            INSERT INTO assistant_usage_events(created_at, model, input_tokens, output_tokens, total_nano_aiu)
            VALUES (\(dateSQL), '\(model)', \(input), \(output), \(nanoAIU));
            """)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteError.queryFailed(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func scalar(_ sql: String) throws -> String? {
        try SQLiteCLIAccessor().queryValue(path: path, sql: sql)
    }

    func contentFiles() throws -> [String: Data] {
        var result = ["": try Data(contentsOf: URL(fileURLWithPath: path))]
        if FileManager.default.fileExists(atPath: path + "-wal") {
            result["-wal"] = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))
        }
        return result
    }
}
