import Foundation
import SQLite3
import XCTest
@testable import OpenUsage

@MainActor
final class AntigravityUsageScannerTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-10-30T12:00:00Z")!

    private func pricing(input: Double = 10) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: [
                "gemini-3.8-flash": ModelRates(
                    inputPerMillion: input, outputPerMillion: 20,
                    cacheWritePerMillion: 12, cacheReadPerMillion: 1
                ),
                "other-test-model": ModelRates(
                    inputPerMillion: 30, outputPerMillion: 40,
                    cacheWritePerMillion: 30, cacheReadPerMillion: 3
                )
            ]),
            secondary: PricingCatalog()
        )
    }

    func testGroupsDailyUsageAndKeepsCacheSeparateWithoutAddingThinkingAgain() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-3.8-flash-n")
        try db.step(index: 1, date: now, input: 100, output: 50, cacheRead: 200, cacheWrite: 30)
        let yesterday = now.addingTimeInterval(-86_400)
        try db.step(index: 2, date: yesterday, input: 20, output: 10)
        let scanner = AntigravityUsageScanner(databasePaths: { [db.path] })

        let scan = try await scanner.scan(now: now, pricing: pricing())

        let days = try XCTUnwrap(scan).series.daily
        XCTAssertEqual(days.map(\.date), [day(now), day(yesterday)])
        XCTAssertEqual(days.map(\.totalTokens), [380, 30])
        XCTAssertEqual(try XCTUnwrap(days[0].costUSD), 0.002_56, accuracy: 1e-12)
        XCTAssertEqual(scan?.modelUsage?.daily.first?.models.first?.model, "gemini-3.8-flash")
    }

    func testUsesEachStepsGenerationModelAndDoesNotMergeSharedMetadataIndices() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-3.8-flash")
        try db.model(index: 1, name: "other-test-model")
        try db.step(index: 1, date: now, input: 100, output: 0)
        try db.step(index: 2, date: now, input: 100, output: 0)
        try db.step(index: 3, date: now, input: 100, output: 0, metadataIndex: 1)

        let scan = try await AntigravityUsageScanner(databasePaths: { [db.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(try XCTUnwrap(scan?.series.daily.first?.costUSD), 0.005, accuracy: 1e-12)
        XCTAssertEqual(Set(scan?.modelUsage?.daily.first?.models.map(\.model) ?? []),
                       ["gemini-3.8-flash", "other-test-model"])
    }

    func testDeduplicatesCopiesAcrossRootsAndSkipsParentReplay() async throws {
        let original = try AntigravityScannerDatabase()
        let duplicate = try AntigravityScannerDatabase()
        let child = try AntigravityScannerDatabase(cascade: "child", trajectory: "child-trajectory")
        defer { original.remove(); duplicate.remove(); child.remove() }
        for db in [original, duplicate] {
            try db.model(index: 0, name: "gemini-3.8-flash")
            try db.step(index: 1, date: now, input: 100, output: 0)
        }
        try child.step(index: 9, date: now, input: 100, output: 0,
                       source: ("conversation", "trajectory", 1))
        let paths = [child.path, duplicate.path, original.path, original.path]

        let scan = try await AntigravityUsageScanner(databasePaths: { paths })
            .scan(now: now, pricing: pricing())

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 100)
    }

    func testFiltersOldRowsBeforeLookingUpTheirMissingModel() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        let cutoff = JSONLScanning.sinceDate(daysBack: 30, now: now)
        try db.step(index: 1, date: cutoff.addingTimeInterval(-1), input: 10, output: 0,
                    metadataIndex: 99)
        try db.model(index: 0, name: "gemini-3.8-flash")
        try db.step(index: 2, date: cutoff, input: 20, output: 0)

        let scan = try await AntigravityUsageScanner(databasePaths: { [db.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertEqual(scan?.series.daily.map(\.date), [day(cutoff)])
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 20)
    }

    func testUnknownModelIsExcludedAndRecordedWithoutInventingAnAlias() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "unpriced-synthetic-model")
        try db.step(index: 1, date: now, input: 10, output: 0)

        let scan = try await AntigravityUsageScanner(databasePaths: { [db.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertTrue(try XCTUnwrap(scan).series.daily.isEmpty)
        XCTAssertEqual(scan?.unknownModelsByDay[day(now)], ["unpriced-synthetic-model"])
    }

    func testMissingModelOrGenerationRowFailsInsteadOfReturningZero() async throws {
        for model in [nil, ""] as [String?] {
            let db = try AntigravityScannerDatabase()
            defer { db.remove() }
            if let model { try db.model(index: 0, name: model) }
            try db.step(index: 1, date: now, input: 10, output: 0)
            await assertFailure(AntigravityUsageScanner(databasePaths: { [db.path] }))
        }
    }

    func testUsageWithoutDateOrSourceFails() async throws {
        for omitDate in [true, false] {
            let db = try AntigravityScannerDatabase()
            defer { db.remove() }
            try db.model(index: 0, name: "gemini-3.8-flash")
            try db.step(index: 1, date: omitDate ? nil : now, input: 10, output: 0,
                        omitSource: !omitDate)
            await assertFailure(AntigravityUsageScanner(databasePaths: { [db.path] }))
        }
    }

    func testMalformedAndOverflowingWireValuesFail() async throws {
        let malformed: [Data] = [
            Data([0x4A, 0x80]),
            Data([0x4A, 0x0B, 0x10] + Array(repeating: 0xFF, count: 9) + [0x02]),
            AntigravityWire.bytes(9, AntigravityWire.number(2, UInt64.max)),
            AntigravityWire.bytes(9, AntigravityWire.number(2, UInt64(Int.max))
                + AntigravityWire.number(3, 1)),
            Data([0x00])
        ]
        for metadata in malformed {
            let db = try AntigravityScannerDatabase()
            defer { db.remove() }
            try db.model(index: 0, name: "gemini-3.8-flash")
            let timestamp = AntigravityWire.bytes(1, AntigravityWire.number(1, UInt64(now.timeIntervalSince1970)))
            let reference = AntigravityWire.bytes(20, AntigravityWire.string(1, "trajectory")
                + AntigravityWire.number(2, 1) + AntigravityWire.string(4, "conversation"))
            try db.rawStep(index: 1, metadata: timestamp + reference + metadata)
            await assertFailure(AntigravityUsageScanner(databasePaths: { [db.path] }))
        }
    }

    func testDistinguishesAbsentDatabaseFromValidEmptyDatabase() async throws {
        let empty = try AntigravityScannerDatabase()
        defer { empty.remove() }
        let absent = empty.directory.appendingPathComponent("absent.db").path
        let missingScan = try await AntigravityUsageScanner(databasePaths: { [absent] })
            .scan(now: now, pricing: pricing())
        let emptyScan = try await AntigravityUsageScanner(databasePaths: { [empty.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertNil(missingScan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent))
        XCTAssertTrue(try XCTUnwrap(emptyScan).series.daily.isEmpty)
    }

    func testMissingSchemaOrCorruptDatabaseThrows() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.execute("DROP TABLE gen_metadata")
        await assertFailure(AntigravityUsageScanner(databasePaths: { [db.path] }))
        let corrupt = db.directory.appendingPathComponent("corrupt.db")
        try Data([1, 2, 3, 4]).write(to: corrupt)
        await assertFailure(AntigravityUsageScanner(databasePaths: { [corrupt.path] }))
    }

    func testEmptyMetadataIsSkippedAndReportedZeroRemainsARealDailyValue() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-3.8-flash")
        try db.rawStep(index: 1, metadata: Data())
        try db.execute("INSERT INTO steps VALUES(2, NULL)")
        try db.step(index: 3, date: now, input: 0, output: 0)

        let scan = try await AntigravityUsageScanner(databasePaths: { [db.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertEqual(scan?.series.daily.count, 1)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 0)
        XCTAssertEqual(scan?.series.daily.first?.costUSD, 0)
    }

    func testOneUnreadableSourceFailsTheWholeScanAndDiscoveryErrorsPropagate() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        let invalid = db.directory.appendingPathComponent("invalid.db")
        try Data([0xFF]).write(to: invalid)
        await assertFailure(AntigravityUsageScanner(databasePaths: { [db.path, invalid.path] }))
        await assertFailure(AntigravityUsageScanner(databasePaths: {
            throw CocoaError(.fileReadNoPermission)
        }))
    }

    func testDatabaseAndWALChangesRefreshAndPricingIsNeverCached() async throws {
        let db = try AntigravityScannerDatabase(wal: true)
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-3.8-flash")
        try db.step(index: 1, date: now, input: 100, output: 0)
        let scanner = AntigravityUsageScanner(databasePaths: { [db.path] })
        let first = try await scanner.scan(now: now, pricing: pricing())
        try db.step(index: 2, date: now, input: 200, output: 0)
        let second = try await scanner.scan(now: now, pricing: pricing())
        let repriced = try await scanner.scan(now: now, pricing: pricing(input: 20))
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try db.step(index: 3, date: now, input: 400, output: 0)
        let third = try await scanner.scan(now: now, pricing: pricing())

        XCTAssertEqual(first?.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(second?.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(try XCTUnwrap(repriced?.series.daily.first?.costUSD), 0.006, accuracy: 1e-12)
        XCTAssertEqual(third?.series.daily.first?.totalTokens, 700)
    }

    func testScanDoesNotModifyDatabaseAndSkipsOpaquePromptFields() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-3.8-flash", opaquePrompt: Data([0xFF, 0x00, 0x80]))
        try db.step(index: 1, date: now, input: 1, output: 0)
        let before = try Data(contentsOf: URL(fileURLWithPath: db.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: db.path)

        let scan = try await AntigravityUsageScanner(databasePaths: { [db.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: db.path)), before)
    }

    func testLocalTrajectoryIdentityMustMatchAndStepZeroUsesProtoDefault() async throws {
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-3.8-flash")
        try db.step(index: 0, date: now, input: 10, output: 0)
        try db.step(index: 1, date: now, input: 100, output: 0,
                    source: ("conversation", "different-trajectory", 1))

        let scan = try await AntigravityUsageScanner(databasePaths: { [db.path] })
            .scan(now: now, pricing: pricing())

        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 10)
    }

    private func assertFailure(_ scanner: AntigravityUsageScanner,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await scanner.scan(now: now, pricing: pricing())
            XCTFail("Expected unreadable usage history", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "Antigravity usage history could not be read. Try again later.", file: file, line: line)
        }
    }

    private func day(_ date: Date) -> String { DailyUsageAccumulator.dayKey(from: date) }
}

@MainActor
private final class AntigravityScannerDatabase {
    let directory: URL
    nonisolated let path: String
    let cascade: String
    let trajectory: String
    private var handle: OpaquePointer?

    init(cascade: String = "conversation", trajectory: String = "trajectory", wal: Bool = false) throws {
        self.cascade = cascade
        self.trajectory = trajectory
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent(cascade + ".db").path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        if wal { try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0") }
        try execute("""
        CREATE TABLE trajectory_meta(trajectory_id TEXT, cascade_id TEXT, trajectory_type INTEGER, source INTEGER);
        CREATE TABLE steps(idx INTEGER PRIMARY KEY, metadata BLOB);
        CREATE TABLE gen_metadata(idx INTEGER PRIMARY KEY, data BLOB, size INTEGER);
        INSERT INTO trajectory_meta VALUES('\(trajectory)', '\(cascade)', 0, 0);
        """)
    }

    func model(index: Int, name: String, opaquePrompt: Data = Data()) throws {
        let chat = AntigravityWire.bytes(1, opaquePrompt) + AntigravityWire.string(19, name)
        let blob = AntigravityWire.bytes(1, chat)
        try execute("INSERT INTO gen_metadata VALUES(\(index), X'\(hex(blob))', \(blob.count))")
    }

    func step(index: Int, date: Date?, input: UInt64, output: UInt64,
              cacheRead: UInt64 = 0, cacheWrite: UInt64 = 0, metadataIndex: UInt64 = 0,
              source: (String, String, Int)? = nil, omitSource: Bool = false) throws {
        var metadata = Data()
        if let date {
            metadata += AntigravityWire.bytes(1, AntigravityWire.number(1, UInt64(date.timeIntervalSince1970)))
        }
        let usage = AntigravityWire.number(2, input) + AntigravityWire.number(3, output)
            + AntigravityWire.number(4, cacheWrite) + AntigravityWire.number(5, cacheRead)
            + AntigravityWire.number(9, output > 0 ? output - 1 : 0) + AntigravityWire.number(10, output > 0 ? 1 : 0)
        metadata += AntigravityWire.bytes(9, usage)
        if !omitSource {
            let origin = source ?? (cascade, trajectory, index)
            let reference = AntigravityWire.string(1, origin.1)
                + AntigravityWire.number(2, UInt64(origin.2)) + AntigravityWire.number(3, metadataIndex)
                + AntigravityWire.string(4, origin.0)
            metadata += AntigravityWire.bytes(20, reference)
        }
        try rawStep(index: index, metadata: metadata)
    }

    func rawStep(index: Int, metadata: Data) throws {
        try execute("INSERT INTO steps VALUES(\(index), X'\(hex(metadata))')")
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func remove() {
        sqlite3_close(handle)
        handle = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}

private enum AntigravityWire {
    static func number(_ field: UInt64, _ value: UInt64) -> Data {
        value == 0 ? Data() : varint(field << 3) + varint(value)
    }

    static func bytes(_ field: UInt64, _ value: Data) -> Data {
        varint(field << 3 | 2) + varint(UInt64(value.count)) + value
    }

    static func string(_ field: UInt64, _ value: String) -> Data { bytes(field, Data(value.utf8)) }

    private static func varint(_ value: UInt64) -> Data {
        var remainder = value
        var bytes = Data()
        repeat {
            let byte = UInt8(remainder & 0x7F)
            remainder >>= 7
            bytes.append(remainder == 0 ? byte : byte | 0x80)
        } while remainder != 0
        return bytes
    }
}
