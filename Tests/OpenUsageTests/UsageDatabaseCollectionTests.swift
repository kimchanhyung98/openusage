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
