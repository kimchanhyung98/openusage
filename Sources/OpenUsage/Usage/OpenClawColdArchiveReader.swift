import CryptoKit
import Foundation

/// 같은 SQLite 스냅샷의 보관 목록 검증 후 필요한 압축 조각 하나만 메모리에 유지.
final class OpenClawColdArchiveReader {
    private struct Archive {
        let session: String
        let generation: String
        let storage: String
        let name: String
        let hash: String
        let eventCount: Int
        let rawBytes: Int
        let archiveBytes: Int
        let lastSequence: Int
        let firstSequence: Int?
        let index: Int?

        init(_ row: [String: Any], parent: Archive? = nil) throws {
            guard let session = UsageJSON.string(row["session_id"]),
                  let generation = parent?.generation ?? UsageJSON.string(row["generation"]),
                  let storage = parent?.storage ?? (row["storage"] as? String), ["sqlite", "file"].contains(storage),
                  let name = row["archive_name"] as? String,
                  name.range(of: "^[a-f0-9]{64}\\.jsonl\\.zst$", options: .regularExpression) != nil,
                  let hash = row["archive_sha256"] as? String,
                  hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let count = UsageLogNumbers.count(row["event_count"]), count > 0,
                  let rawBytes = UsageLogNumbers.count(row["raw_bytes"]),
                  let archiveBytes = UsageLogNumbers.count(row["archive_bytes"]),
                  let lastSequence = UsageLogNumbers.count(row["last_seq"]) else { throw CocoaError(.coderReadCorrupt) }
            let firstSequence = UsageLogNumbers.count(row["first_seq"])
            let index = UsageLogNumbers.count(row["chunk_index"])
            if let parent {
                guard session == parent.session, let firstSequence, firstSequence <= lastSequence,
                      index != nil else { throw CocoaError(.coderReadCorrupt) }
            }
            self.session = session
            self.generation = generation
            self.storage = storage
            self.name = name
            self.hash = hash
            eventCount = count
            self.rawBytes = rawBytes
            self.archiveBytes = archiveBytes
            self.lastSequence = lastSequence
            self.firstSequence = firstSequence
            self.index = index
        }
    }

    private let database: UsageDatabase
    private let directory: URL
    private let tables: Set<String>
    private var session: String?
    private var archive: Archive?
    private var chunks: [Archive] = []
    private var loadedName: String?
    private var payloads: [Int: Data] = [:]

    init(database: UsageDatabase, path: String, tables: Set<String>) {
        self.database = database
        let storeDirectory = URL(fileURLWithPath: path).deletingLastPathComponent()
        directory = (storeDirectory.lastPathComponent == "agent"
            ? storeDirectory.deletingLastPathComponent().appendingPathComponent("sessions") : storeDirectory)
            .appendingPathComponent("cold")
        self.tables = tables
    }

    func payload(session requestedSession: String, sequence: Int) throws -> Data? {
        if session != requestedSession { try loadManifest(session: requestedSession) }
        guard let archive else { return nil }
        let selected: Archive
        if chunks.isEmpty {
            selected = archive
        } else {
            var low = 0
            var high = chunks.count
            while low < high {
                let middle = low + (high - low) / 2
                if chunks[middle].lastSequence < sequence { low = middle + 1 } else { high = middle }
            }
            guard low < chunks.count else { throw CocoaError(.coderReadCorrupt) }
            let chunk = chunks[low]
            guard let first = chunk.firstSequence, first <= sequence else { throw CocoaError(.coderReadCorrupt) }
            selected = chunk
        }
        if loadedName != selected.name {
            payloads = [:]
            payloads = try Self.decode(try readBytes(selected), archive: selected)
            loadedName = selected.name
        }
        guard let payload = payloads[sequence] else { throw CocoaError(.coderReadCorrupt) }
        return payload
    }

    private func loadManifest(session requestedSession: String) throws {
        session = requestedSession
        archive = nil
        chunks = []
        loadedName = nil
        payloads = [:]
        guard tables.contains("session_transcript_cold_archives") else { return }
        let fields = "session_id, generation, storage, archive_name, archive_sha256, event_count, raw_bytes, archive_bytes, last_seq"
        try database.rows("SELECT \(fields) FROM session_transcript_cold_archives WHERE session_id = \(Self.literal(requestedSession))") {
            guard archive == nil else { throw CocoaError(.coderReadCorrupt) }
            archive = try Archive($0)
        }
        guard let archive, tables.contains("session_transcript_cold_archive_chunks") else { return }
        let chunkFields = "session_id, chunk_index, archive_name, archive_sha256, first_seq, last_seq, event_count, raw_bytes, archive_bytes"
        try database.rows("SELECT \(chunkFields) FROM session_transcript_cold_archive_chunks WHERE session_id = \(Self.literal(requestedSession)) ORDER BY chunk_index") {
            chunks.append(try Archive($0, parent: archive))
        }
        if !chunks.isEmpty { try verifyChunks(archive) }
    }

    private func verifyChunks(_ archive: Archive) throws {
        var count = 0
        var rawBytes = chunks.count - 1
        var archiveBytes = 0
        var previous: Int?
        var manifest: [[Any]] = []
        for (index, chunk) in chunks.enumerated() {
            guard chunk.index == index, let first = chunk.firstSequence,
                  previous.map({ first > $0 }) ?? true,
                  let nextCount = UsageLogNumbers.sum(count, chunk.eventCount),
                  let nextRaw = UsageLogNumbers.sum(rawBytes, chunk.rawBytes),
                  let nextBytes = UsageLogNumbers.sum(archiveBytes, chunk.archiveBytes) else { throw CocoaError(.coderReadCorrupt) }
            count = nextCount
            rawBytes = nextRaw
            archiveBytes = nextBytes
            previous = chunk.lastSequence
            manifest.append([index, chunk.name, chunk.hash, first, chunk.lastSequence, chunk.eventCount, chunk.rawBytes, chunk.archiveBytes])
        }
        let hash = Self.sha256(try JSONSerialization.data(withJSONObject: manifest))
        guard count == archive.eventCount, rawBytes == archive.rawBytes, archiveBytes == archive.archiveBytes,
              previous == archive.lastSequence, hash == archive.hash,
              archive.name == hash + ".jsonl.zst" else { throw CocoaError(.coderReadCorrupt) }
    }

    private func readBytes(_ archive: Archive) throws -> Data {
        let bytes: Data
        if archive.storage == "sqlite" {
            let table = archive.index == nil ? "session_transcript_cold_archives" : "session_transcript_cold_archive_chunks"
            let index = archive.index.map { " AND chunk_index = \($0)" } ?? ""
            var embedded: Data?
            try database.rows("SELECT archive_blob FROM \(table) WHERE session_id = \(Self.literal(archive.session))\(index)") {
                embedded = $0["archive_blob"] as? Data
            }
            guard let embedded else { throw CocoaError(.coderReadCorrupt) }
            bytes = embedded
        } else {
            let file = directory.appendingPathComponent(archive.name)
            guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == archive.archiveBytes else {
                throw CocoaError(.coderReadCorrupt)
            }
            bytes = try Data(contentsOf: file)
        }
        guard bytes.count == archive.archiveBytes, Self.sha256(bytes) == archive.hash else { throw CocoaError(.coderReadCorrupt) }
        return bytes
    }

    private static func decode(_ bytes: Data, archive: Archive) throws -> [Int: Data] {
        let decoded = try UsageZstandard.decode(bytes, maximumBytes: 64 * 1024 * 1024)
        var payloads: [Int: Data] = [:]
        var headerSeen = false
        var rawBytes = 0
        var lastSequence: Int?
        var offset = decoded.startIndex
        while offset < decoded.endIndex {
            try Task.checkCancellation()
            let end = decoded.range(of: Data([0x0A]), in: offset..<decoded.endIndex)?.lowerBound ?? decoded.endIndex
            let line = decoded[offset..<end]
            if line.allSatisfy(isWhitespace) {
                guard decoded[offset...].allSatisfy(isWhitespace) else { throw CocoaError(.coderReadCorrupt) }
                break
            }
            let object = try UsageJSON.object(line)
            guard let kind = object["kind"] as? String else { throw CocoaError(.coderReadCorrupt) }
            if !headerSeen {
                guard kind == "header", integer(object["version"]) == 1,
                      object["sessionId"] as? String == archive.session,
                      object["generation"] as? String == archive.generation else { throw CocoaError(.coderReadCorrupt) }
                headerSeen = true
            } else {
                guard kind != "header", let row = object["row"] as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
                if kind == "event" {
                    guard let sequence = integer(row["seq"]), integer(row["created_at"]) != nil,
                          let text = row["event_json"] as? String,
                          lastSequence.map({ sequence > $0 }) ?? (archive.firstSequence.map({ sequence == $0 }) ?? true)
                    else { throw CocoaError(.coderReadCorrupt) }
                    let payload = Data(text.utf8)
                    guard let total = UsageLogNumbers.sum(rawBytes, payload.count, payloads.isEmpty ? 0 : 1) else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    rawBytes = total
                    payloads[sequence] = payload
                    lastSequence = sequence
                } else if !validAuxiliary(kind, row: row) {
                    throw CocoaError(.coderReadCorrupt)
                }
            }
            offset = end < decoded.endIndex ? end + 1 : decoded.endIndex
        }
        guard headerSeen, payloads.count == archive.eventCount, rawBytes == archive.rawBytes,
              lastSequence == archive.lastSequence else { throw CocoaError(.coderReadCorrupt) }
        return payloads
    }

    private static func validAuxiliary(_ kind: String, row: [String: Any]) -> Bool {
        func strings(_ keys: [String]) -> Bool { keys.allSatisfy { row[$0] is String || row[$0] is NSNull } }
        func integers(_ keys: [String]) -> Bool { keys.allSatisfy { integer(row[$0]) != nil } }
        func nullableIntegers(_ keys: [String]) -> Bool { keys.allSatisfy { row[$0] is NSNull || integer(row[$0]) != nil } }
        switch kind {
        case "identity":
            return row["event_id"] is String && integers(["seq", "created_at"])
                && strings(["event_type", "parent_id", "message_idempotency_key"])
        case "active":
            return integers(["active_position", "event_seq"]) && nullableIntegers(["message_position", "context_eligible"])
        case "index":
            return integers(["indexed_seq", "needs_rebuild", "active_event_count", "active_message_count", "updated_at"])
                && strings(["leaf_event_id"])
        case "fts":
            return strings(["text", "message_id", "role"])
                && (row["timestamp"] is String || row["timestamp"] is NSNull || ProviderParse.number(row["timestamp"]) != nil)
        default: return false
        }
    }

    static func sha256(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        if let integer = Int(value.stringValue) { return integer }
        guard let number = ProviderParse.number(value), abs(number) <= 9_007_199_254_740_991 else { return nil }
        return Int(exactly: number)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool { [0x20, 0x09, 0x0A, 0x0D].contains(byte) }

    private static func literal(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
}
