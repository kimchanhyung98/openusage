import SQLite3
import XCTest
import libzstd
@testable import OpenUsage

@MainActor
final class UsageDatabaseCollectionTests: XCTestCase {

    func testReadOnlyDatabaseDoesNotCreateMissingStore() throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing.db")
        XCTAssertThrowsError(try UsageDatabase(path: missing.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testReadOnlyDatabaseSeesCommittedWALWhileWriterRemainsOpen() throws {
        let writer = try UsageTestDatabase()
        try writer.execute("CREATE TABLE usage (tokens INTEGER); INSERT INTO usage VALUES (120)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.file.path + "-wal"))
        let first = try UsageDatabase(path: writer.file.path)
        var tokens: [Int] = []
        try first.rows("SELECT tokens FROM usage ORDER BY rowid") { row in
            tokens.append(try XCTUnwrap(row["tokens"] as? NSNumber).intValue)
        }
        XCTAssertEqual(tokens, [120])
        try writer.execute("INSERT INTO usage VALUES (30)")
        tokens.removeAll()
        try first.rows("SELECT tokens FROM usage ORDER BY rowid") { row in
            tokens.append(try XCTUnwrap(row["tokens"] as? NSNumber).intValue)
        }
        XCTAssertEqual(tokens, [120], "an active reader must keep its snapshot")
        let second = try UsageDatabase(path: writer.file.path)
        tokens.removeAll()
        try second.rows("SELECT tokens FROM usage ORDER BY rowid") { row in
            tokens.append(try XCTUnwrap(row["tokens"] as? NSNumber).intValue)
        }
        XCTAssertEqual(tokens, [120, 30])
    }

    func testZstandardFramesBoundsAndTruncation() throws {
        let first = try Self.compress(Data("first\n".utf8))
        let second = try Self.compress(Data("second\n".utf8))
        XCTAssertEqual(try UsageZstandard.decode(first + second), Data("first\nsecond\n".utf8))
        let skippable = Data([0x50, 0x2A, 0x4D, 0x18, 0, 0, 0, 0])
        XCTAssertEqual(try UsageZstandard.decodeIfNeeded(skippable + first), Data("first\n".utf8))
        XCTAssertThrowsError(try UsageZstandard.decode(first.dropLast()))
        XCTAssertThrowsError(try UsageZstandard.decode(first, maximumBytes: 2))
    }

    private static func compress(_ input: Data) throws -> Data {
        var output = Data(count: ZSTD_compressBound(input.count))
        let capacity = output.count
        let count = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { target in ZSTD_compress(target.baseAddress, capacity, bytes.baseAddress, bytes.count, 1) }
        }
        guard ZSTD_isError(count) == 0 else { throw CocoaError(.coderInvalidValue) }
        output.count = count
        return output
    }
    func testKiloUsesDirectStepsAndReadsCommittedWALChanges() async throws {
        let database = try UsageTestDatabase()
        let sql = try String(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("UsageCollection/kilo/fixture.sql"), encoding: .utf8)
        try database.execute(sql)
        let file = database.file
        let collector = UsageSQLiteCollector(sourceID: "kilo", roots: [file], includeFile: { _ in true }, parse: KiloUsageParser.database)
        let first = await collector.collect(since: .distantPast)
        let records = try XCTUnwrap(first?.records)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.reduce(0) { $0 + $1.totalTokens }, 260)
        XCTAssertEqual(records.reduce(0) { $0 + ($1.recordedCostUSD ?? 0) }, 0.34, accuracy: 1e-9)
        XCTAssertTrue(records.allSatisfy { $0.issues.isEmpty })
        let before = try Data(contentsOf: file)
        try database.execute("UPDATE part SET data=json_set(data,'$.cost',0.4) WHERE id='k-step-parent'")
        let second = await collector.collect(since: .distantPast)
        XCTAssertEqual(try XCTUnwrap(second?.records.reduce(0) { $0 + ($1.recordedCostUSD ?? 0) }), 0.64, accuracy: 1e-9)
        XCTAssertEqual(try Data(contentsOf: file), before, "The new committed usage is in the WAL, not a rewritten DB file")
    }

    func testKiroSQLiteKeepsRequestTokensWithoutAssigningUnmatchedCredits() async throws {
        let database = try UsageTestDatabase()
        try database.execute("""
        CREATE TABLE conversations_v2(conversation_id TEXT,value TEXT);
        INSERT INTO conversations_v2 VALUES('s','{"history":[{"request_metadata":{"input_tokens":100,"output_tokens":10,"request_start_timestamp_ms":1793494800000}}],"user_turn_metadata":{"usage_info":[{"unit":"credit","value":0.5}]}}');
        """)
        let result = try KiroLegacyUsageParser.database(UsageDatabase(path: database.file.path), path: database.file.path)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.first?.totalTokens, 110)
        XCTAssertNil(result.first?.recordedCostUSD)
        XCTAssertEqual(result.last?.recordedCostUSD, 0.02)
        XCTAssertTrue(result.last?.issues.contains(.invalidMetadata) == true)
    }

}

@MainActor
private final class UsageTestDatabase {
    let file: URL
    private var handle: OpaquePointer?

    init() throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        file = directory.appendingPathComponent("usage.db")
        guard sqlite3_open(file.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.coderInvalidValue) }
    }

    isolated deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
