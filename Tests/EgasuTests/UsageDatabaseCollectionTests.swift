import SQLite3
import XCTest
import libzstd
@testable import Egasu

@MainActor
final class UsageDatabaseCollectionTests: XCTestCase {
    func testOpenClawJSONLAndCompressedSQLiteCountOneRequest() async throws {
        let database = try UsageTestDatabase()
        let header = #"{"type":"session","id":"s1"}"#
        let message = #"{"type":"message","id":"e1","message":{"role":"assistant","provider":"anthropic","model":"claude-sonnet-4-6","timestamp":1793494801000,"usage":{"input":100,"output":20,"cacheRead":50,"cacheWrite":10,"cost":{"total":0.12}}}}"#
        let compressed = try Self.compress(Data(message.utf8)).map { String(format: "%02x", $0) }.joined()
        try database.execute("""
        CREATE TABLE transcript_events(session_id TEXT,seq INTEGER,event_json TEXT,event_zstd BLOB,event_utf8_bytes INTEGER);
        INSERT INTO transcript_events VALUES('s1',0,'\(header)',NULL,NULL);
        INSERT INTO transcript_events VALUES('s1',1,NULL,X'\(compressed)',\(message.utf8.count));
        """)
        let file = database.file
        let transcript = file.deletingLastPathComponent().appendingPathComponent("s1.jsonl")
        try UsageRecordFixture.write(header + "\n" + message, to: transcript)
        let fileCollector = UsageFileCollector(sourceID: "openclaw", roots: [transcript], scanner: IncrementalJSONLScanner(),
                                               includeFile: { _ in true }, parse: OpenClawSessionParser.parse)
        let sqliteCollector = UsageSQLiteCollector(sourceID: "openclaw", roots: [file], includeFile: { _ in true },
                                                   parse: OpenClawSessionParser.database)
        let collected = await UsageCollectionCoordinator(collectors: [fileCollector, sqliteCollector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.totalTokens, 180)
        XCTAssertEqual(result.records.first?.recordedCostUSD, 0.12)
        try database.execute("INSERT INTO transcript_events VALUES('s1',2,NULL,NULL,NULL)")
        let missing = await sqliteCollector.collect(since: .distantPast)
        XCTAssertTrue(missing?.records.contains { $0.kind == "missing-payload" && $0.issues.contains(.invalidMetadata) } == true)
    }

    func testHermesModelTotalsReplaceSessionRollupAndPreserveIntervalLimits() async throws {
        let database = try UsageTestDatabase()
        try database.execute("""
        CREATE TABLE sessions(id TEXT,model TEXT,billing_provider TEXT,started_at REAL,ended_at REAL,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER);
        INSERT INTO sessions VALUES('s','claude-sonnet-4-6','anthropic',1793494800,1793494810,1200,300,50,20,10);
        CREATE TABLE session_model_usage(session_id TEXT,model TEXT,billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,task TEXT,first_seen REAL,last_seen REAL,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,estimated_cost_usd REAL,actual_cost_usd REAL,cost_status TEXT);
        INSERT INTO session_model_usage VALUES('s','claude-sonnet-4-6','anthropic','','','',1793494800,1793494810,1200,300,50,20,10,0,0.34,'actual');
        INSERT INTO session_model_usage VALUES('s','claude-sonnet-4-6','anthropic','','','compression',1793494800,1793667600,100,20,0,0,0,0.02,0,'estimated');
        """)
        let file = database.file
        let collector = UsageSQLiteCollector(sourceID: "hermes", roots: [file], includeFile: { _ in true }, parse: HermesUsageParser.database)
        let collection = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(collection)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 1690)
        XCTAssertEqual(result.records.filter { $0.issues.contains(.invalidMetadata) }.count, 1)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1570)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.34)
        XCTAssertNotNil(scan.metadataWarning)
    }

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

    func testOverlappingAggregateKeepsItsIncompleteWarningAtWindowBoundary() async throws {
        let database = try UsageTestDatabase()
        let since = Date(timeIntervalSince1970: 1793494800)
        let overlap = UsageRecord(
            sourceID: "hermes", formatID: "hermes", granularity: .aggregate, kind: "session",
            timestamp: since.addingTimeInterval(-86400), intervalEnd: since.addingTimeInterval(60),
            providerID: "anthropic", totalTokens: 120, issues: [.invalidMetadata]
        )
        var old = overlap
        old.intervalEnd = since.addingTimeInterval(-1)
        var unfinished = overlap
        unfinished.intervalEnd = nil
        var request = overlap
        request.granularity = .request
        let rows = [overlap, old, unfinished, request]
        let collector = UsageSQLiteCollector(
            sourceID: "hermes", roots: [database.file], includeFile: { _ in true }, parse: { _, _ in rows }
        )
        let collection = await collector.collect(since: since)
        let result = try XCTUnwrap(collection)
        XCTAssertEqual(result.records, [overlap, unfinished])
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: since, pricing: .empty))
        XCTAssertEqual(scan.rejectedMetadataRows, 2)
        XCTAssertNotNil(scan.metadataWarning)
        XCTAssertNil(scan.usageHistory)
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

    func testDeepSeekLatestGenerationDoesNotSumOlderFiles() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let row = #"{"type":"assistant/message","seq":1,"time":1793494800000,"data":{"usage":{"inputTokens":100,"outputTokens":10}}}"#
        for version in 0...2 {
            let header = "{\"type\":\"session\",\"id\":\"s\",\"version\":\(version),\"isSeeded\":false}"
            let contents = header + "\n" + row + "\n"
            let name = version == 0 ? "session.jsonl" : "session.v\(version).jsonl"
            try UsageRecordFixture.write(contents, to: directory.appendingPathComponent(name))
            if version == 2 {
                try UsageRecordFixture.write(Self.compress(Data(contents.utf8)), to: directory.appendingPathComponent(name + ".zstd"))
            }
        }
        let collector = UsageFileCollector(sourceID: "dsh", roots: [directory], scanner: IncrementalJSONLScanner(),
                                           includeFile: DeepSeekSessionParser.isCurrentGeneration, parse: DeepSeekSessionParser.parse)
        let result = await collector.collect(since: .distantPast)
        XCTAssertEqual(result?.records.count, 1)
        XCTAssertEqual(result?.records.first?.totalTokens, 110)
        XCTAssertEqual(result?.sources.first?.completedStores, 1)
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
