import Foundation
import SQLite3

/// WAL을 포함한 읽기 전용 스냅샷. 도구별 SQL을 실행하며 결과에 대화 본문은 보관하지 않음.
final class UsageDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw CocoaError(.fileReadUnknown)
        }
        guard sqlite3_busy_timeout(opened, 1000) == SQLITE_OK,
              sqlite3_exec(opened, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened)
            throw CocoaError(.fileReadUnknown)
        }
        handle = opened
    }

    deinit {
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
        sqlite3_close(handle)
    }

    func tables() throws -> Set<String> {
        var tables: Set<String> = []
        try rows("SELECT name FROM sqlite_master WHERE type = 'table'") { row in
            if let name = row["name"] as? String { tables.insert(name) }
        }
        return tables
    }

    func columns(in table: String) throws -> Set<String> {
        var columns: Set<String> = []
        try rows("PRAGMA table_info(\(Self.identifier(table)))") { row in
            if let name = row["name"] as? String { columns.insert(name) }
        }
        return columns
    }

    static func identifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    func rows(_ sql: String, consume: ([String: Any]) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw CocoaError(.coderReadCorrupt)
        }
        defer { sqlite3_finalize(statement) }
        while true {
            try Task.checkCancellation()
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return
            case SQLITE_ROW: break
            default: throw CocoaError(.fileReadUnknown)
            }
            var row: [String: Any] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = NSNumber(value: sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = NSNumber(value: sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index),
                          let value = String(bytes: UnsafeBufferPointer(
                            start: bytes, count: Int(sqlite3_column_bytes(statement, index))
                          ), encoding: .utf8) else { throw CocoaError(.coderReadCorrupt) }
                    row[name] = value
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let bytes = sqlite3_column_blob(statement, index) else {
                        if count == 0 { row[name] = Data(); continue }
                        throw CocoaError(.coderReadCorrupt)
                    }
                    row[name] = Data(bytes: bytes, count: count)
                default: break
                }
            }
            try consume(row)
        }
    }
}

struct UsageSQLiteCollector: UsageCollecting {
    let sourceID: String
    var providerID: String? = nil
    let roots: [URL]
    let includeFile: @Sendable (URL) -> Bool
    let parse: @Sendable (UsageDatabase, String) throws -> [UsageRecord]
    var useDiscoveredPathForParser = false

    func collect(since: Date) async -> UsageCollection? {
        guard !Task.isCancelled else { return nil }
        let discovery = UsageFileDiscovery.files(under: roots, matching: includeFile)
        guard !Task.isCancelled else { return nil }
        var records: [UsageRecord] = []
        var state = UsageSourceState(sourceID: sourceID, providerID: providerID, failedStores: discovery.failures)
        for file in discovery.files {
            guard !Task.isCancelled else { return nil }
            do {
                let parserPath = useDiscoveredPathForParser ? (file.discoveredPath ?? file.path) : file.path
                let rows = try parse(UsageDatabase(path: file.path), parserPath)
                guard !Task.isCancelled else { return nil }
                UsageRecordDiagnostics.report(rows)
                records += rows.filter { $0.overlaps(since: since) }
                state.completedStores += 1
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                state.failedStores += 1
            }
        }
        guard !Task.isCancelled else { return nil }
        if state.failedStores > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .storage, providerID: sourceID,
                localContext: "source=\(sourceID); database_read_failures=\(state.failedStores)"
            )
        }
        return UsageCollection(records: records, sources: [state])
    }
}
