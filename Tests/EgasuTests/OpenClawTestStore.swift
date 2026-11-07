import CryptoKit
import SQLite3
import XCTest
import libzstd
@testable import Egasu

@MainActor
final class OpenClawTestStore {
    @MainActor
    struct ColdArchive {
        let events: [(Int, String)]
        let bytes: Data
        let hash: String
        var name: String { hash + ".jsonl.zst" }
        var rawBytes: Int { events.reduce(0) { $0 + $1.1.utf8.count } + events.count - 1 }

        init(events: [(Int, String)], transform: (([[String: Any]]) -> [[String: Any]])? = nil) throws {
            self.events = events
            var envelope: [[String: Any]] = [["kind": "header", "version": 1, "sessionId": "s1", "generation": "g1"]]
            envelope += events.map { ["kind": "event", "row": ["seq": $0.0, "event_json": $0.1, "created_at": 1793494800]] }
            let lines = try (transform?(envelope) ?? envelope).map { try OpenClawTestStore.json($0) }
            bytes = try OpenClawTestStore.compress(Data((lines.joined(separator: "\n") + "\n").utf8))
            hash = OpenClawTestStore.sha256(bytes)
        }
    }

    static let header = #"{"type":"session","id":"s1"}"#
    let directory: URL
    let file: URL
    var coldDirectory: URL { directory.appendingPathComponent("sessions/cold") }
    private var handle: OpaquePointer?

    init() throws {
        directory = try UsageRecordFixture.temporaryDirectory()
        file = directory.appendingPathComponent("agent/openclaw-agent.sqlite")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(file.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE transcript_events(
          session_id TEXT,seq INTEGER,event_json TEXT,event_zstd BLOB,event_utf8_bytes INTEGER,PRIMARY KEY(session_id,seq));
        CREATE TABLE session_transcript_cold_archives(
          session_id TEXT PRIMARY KEY,generation TEXT,archive_name TEXT,archive_sha256 TEXT,event_count INTEGER,
          raw_bytes INTEGER,archive_bytes INTEGER,last_seq INTEGER,storage TEXT,archive_blob BLOB);
        CREATE TABLE session_transcript_cold_archive_chunks(
          session_id TEXT,chunk_index INTEGER,archive_name TEXT,archive_sha256 TEXT,first_seq INTEGER,last_seq INTEGER,
          event_count INTEGER,raw_bytes INTEGER,archive_bytes INTEGER,archive_blob BLOB,PRIMARY KEY(session_id,chunk_index));
        CREATE TABLE session_transcript_archives(
          session_id TEXT,generation TEXT,encoding TEXT,archive_blob BLOB,archive_sha256 TEXT,PRIMARY KEY(session_id,generation));
        """)
    }

    func install(_ archives: [ColdArchive], storage: String = "sqlite") throws {
        let first = try XCTUnwrap(archives.first)
        let last = try XCTUnwrap(archives.last)
        let manifest: [[Any]] = archives.enumerated().map { index, archive in
            [index, archive.name, archive.hash, archive.events.first!.0, archive.events.last!.0,
             archive.events.count, archive.rawBytes, archive.bytes.count]
        }
        let hash = archives.count == 1 ? first.hash : Self.sha256(try JSONSerialization.data(withJSONObject: manifest))
        let count = archives.reduce(0) { $0 + $1.events.count }
        let rawBytes = archives.reduce(archives.count - 1) { $0 + $1.rawBytes }
        let archiveBytes = archives.reduce(0) { $0 + $1.bytes.count }
        let parentBlob = storage == "sqlite" ? Self.blob(archives.count == 1 ? first.bytes : Data()) : "NULL"
        try execute("""
        INSERT INTO session_transcript_cold_archives VALUES(
          's1','g1','\(hash).jsonl.zst','\(hash)',\(count),\(rawBytes),\(archiveBytes),\(last.events.last!.0),'\(storage)',\(parentBlob));
        """)
        for (index, archive) in archives.enumerated() {
            for (sequence, text) in archive.events {
                try execute("INSERT INTO transcript_events VALUES('s1',\(sequence),NULL,NULL,\(text.utf8.count))")
            }
            if archives.count > 1 {
                let blob = storage == "sqlite" ? Self.blob(archive.bytes) : "NULL"
                try execute("""
                INSERT INTO session_transcript_cold_archive_chunks VALUES(
                  's1',\(index),'\(archive.name)','\(archive.hash)',\(archive.events.first!.0),\(archive.events.last!.0),
                  \(archive.events.count),\(archive.rawBytes),\(archive.bytes.count),\(blob));
                """)
            }
            if storage == "file" { try UsageRecordFixture.write(archive.bytes, to: coldDirectory.appendingPathComponent(archive.name)) }
        }
    }

    func records() throws -> [UsageRecord] {
        try OpenClawSessionParser.database(UsageDatabase(path: file.path), path: file.path)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard status == SQLITE_OK else {
            throw NSError(domain: "OpenClawTestStore", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "sqlite3_exec failed"
            ])
        }
    }

    static func message(
        id: String, provider: String = "anthropic", cost: Double, input: Int = 100, output: Int = 20, report: String? = nil
    ) throws -> String {
        var usage: [String: Any] = ["input": input, "output": output, "totalTokens": input + output,
                                    "cost": ["total": cost, "totalOrigin": "provider-billed"]]
        if let report { usage["usageReport"] = ["state": report] }
        return try json(["type": "message", "id": id, "message": [
            "role": "assistant", "provider": provider, "model": "claude-sonnet-4-6", "timestamp": 1793494801000, "usage": usage
        ]])
    }

    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func compress(_ input: Data) throws -> Data {
        var output = Data(count: ZSTD_compressBound(input.count))
        let capacity = output.count
        let count = input.withUnsafeBytes { bytes in
            output.withUnsafeMutableBytes { target in ZSTD_compress(target.baseAddress, capacity, bytes.baseAddress, bytes.count, 1) }
        }
        guard ZSTD_isError(count) == 0 else { throw CocoaError(.coderInvalidValue) }
        output.count = count
        return output
    }

    static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    static func blob(_ bytes: Data) -> String { "X'" + bytes.map { String(format: "%02x", $0) }.joined() + "'" }
    static func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

    isolated deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: directory)
    }
}
