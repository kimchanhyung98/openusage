import Foundation
import SQLite3

/// 대화 DB 하나의 일관된 읽기 스냅샷에서 최근 사용량만 추출.
final class AntigravityUsageDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(path, &opened, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw AntigravityUsageScanError.unreadable
        }
        guard sqlite3_busy_timeout(opened, 1_000) == SQLITE_OK else {
            sqlite3_close(opened)
            throw AntigravityUsageScanError.unreadable
        }
        handle = opened
    }

    deinit { sqlite3_close(handle) }

    func records(since: Date) throws -> [AntigravityUsageRecord] {
        try execute("BEGIN")
        var committed = false
        defer { if !committed { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) } }
        let identity = try localIdentity()
        let steps = try prepare("SELECT idx, metadata FROM steps ORDER BY idx")
        defer { sqlite3_finalize(steps) }
        let generation = try prepare("SELECT data FROM gen_metadata WHERE idx = ?1")
        defer { sqlite3_finalize(generation) }
        var models: [UInt32: String] = [:]
        var records: [AntigravityUsageRecord] = []

        while try next(steps) {
            try Task.checkCancellation()
            guard sqlite3_column_type(steps, 0) == SQLITE_INTEGER,
                  let index = UInt32(exactly: sqlite3_column_int64(steps, 0))
            else { throw AntigravityUsageScanError.unreadable }
            if sqlite3_column_type(steps, 1) == SQLITE_NULL { continue }
            let step = try AntigravityUsageRecord.parseStep(blob(steps, column: 1))
            guard let tokens = step.tokens else { continue }
            guard let date = step.date else { throw AntigravityUsageScanError.unreadable }
            guard date >= since else { continue }
            guard let source = step.source, !source.cascade.isEmpty, !source.trajectory.isEmpty,
                  let identity
            else { throw AntigravityUsageScanError.unreadable }
            // 복제된 부모 단계는 원본 DB에서만 집계. 서로 다른 단계의 공통 generation 참조는 유지.
            guard source.cascade == identity.cascade, source.trajectory == identity.trajectory,
                  source.step == index
            else { continue }

            let model: String
            if let cached = models[source.metadataIndex] {
                model = cached
            } else {
                model = try readModel(generation, index: source.metadataIndex)
                models[source.metadataIndex] = model
            }
            records.append(AntigravityUsageRecord(
                identity: .init(cascade: source.cascade, trajectory: source.trajectory, step: source.step),
                date: date, model: model, tokens: tokens
            ))
        }
        try execute("COMMIT")
        committed = true
        return records
    }

    private func localIdentity() throws -> (cascade: String, trajectory: String)? {
        let statement = try prepare("SELECT trajectory_id, cascade_id FROM trajectory_meta")
        defer { sqlite3_finalize(statement) }
        guard try next(statement) else { return nil }
        let trajectory = try string(statement, column: 0)
        let cascade = try string(statement, column: 1)
        guard !trajectory.isEmpty, !cascade.isEmpty, try !next(statement) else {
            throw AntigravityUsageScanError.unreadable
        }
        return (cascade, trajectory)
    }

    private func readModel(_ statement: OpaquePointer, index: UInt32) throws -> String {
        guard sqlite3_reset(statement) == SQLITE_OK,
              sqlite3_bind_int64(statement, 1, Int64(index)) == SQLITE_OK,
              try next(statement)
        else { throw AntigravityUsageScanError.unreadable }
        let model = try AntigravityUsageRecord.parseModel(blob(statement, column: 0))
        guard try !next(statement) else { throw AntigravityUsageScanError.unreadable }
        return model
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            if let statement { sqlite3_finalize(statement) }
            throw AntigravityUsageScanError.unreadable
        }
        return statement
    }

    private func next(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw AntigravityUsageScanError.unreadable
        }
    }

    private func blob(_ statement: OpaquePointer, column: Int32) throws -> UnsafeRawBufferPointer {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB else {
            throw AntigravityUsageScanError.unreadable
        }
        let count = Int(sqlite3_column_bytes(statement, column))
        let pointer = sqlite3_column_blob(statement, column)
        guard count == 0 || pointer != nil else { throw AntigravityUsageScanError.unreadable }
        return UnsafeRawBufferPointer(start: pointer, count: count)
    }

    private func string(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column)
        else { throw AntigravityUsageScanError.unreadable }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw AntigravityUsageScanError.unreadable
        }
        return value
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw AntigravityUsageScanError.unreadable
        }
    }
}
