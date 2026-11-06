import Foundation

enum OpenClawSessionParser {
    private struct State {
        var session: String?
        var parent: String?
        var provider: String?
        var model: String?

        mutating func record(_ object: [String: Any], path: String) -> UsageRecord? {
            switch object["type"] as? String {
            case "session":
                session = UsageJSON.string(object["id"]) ?? session
                parent = UsageJSON.string(object["parentSession"])
                return nil
            case "model_change":
                provider = UsageJSON.string(object["provider"])
                model = UsageJSON.string(object["modelId"])
                return nil
            case "custom":
                if object["customType"] as? String == "model-snapshot", let data = object["data"] as? [String: Any] {
                    provider = UsageJSON.string(data["provider"])
                    model = UsageJSON.string(data["modelId"])
                }
                return nil
            case "message": break
            default: return nil
            }
            guard var message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                  message["api"] as? String != "openclaw-transcript" else { return nil }
            if message["provider"] as? String == "openclaw",
               ["delivery-mirror", "gateway-injected"].contains(message["model"] as? String ?? "") { return nil }
            if let value = UsageJSON.string(message["provider"]) { provider = value }
            if let value = UsageJSON.string(message["model"]) { model = value }
            message["provider"] = provider
            message["model"] = model
            var normalized = object
            normalized["message"] = message
            guard var result = PiSessionParser.record(normalized, sourceID: "openclaw") else { return nil }
            result.formatID = "openclaw-session"
            result.filePath = path
            result.sessionID = session
            result.parentSession = parent
            if let usage = message["usage"] as? [String: Any] {
                if let cost = usage["cost"] as? [String: Any], cost["totalOrigin"] as? String == "provider-billed" {
                    result.costOrigin = .reported
                    result.zeroCostIsUnknown = false
                }
                if let report = usage["usageReport"] as? [String: Any], report["state"] as? String == "unavailable" {
                    result.issues.insert(.invalidMetadata)
                }
            }
            if let mirror = UsageJSON.string(message["idempotencyKey"]), mirror.hasPrefix("codex-app-server:") {
                // 마지막 응답 mirror는 전체 turn 원장을 대체하지 않음. native rollout과 함께 집계 금지.
                result.id = mirror
                result.issues.insert(.unresolvedMirror)
            }
            return result
        }
    }

    static func parse(_ data: Data, path: String) throws -> [UsageRecord] {
        try parseTranscript(UsageZstandard.decodeIfNeeded(data), path: path, allowIncompleteTail: true)
    }

    private static func parseTranscript(
        _ data: Data, path: String, session: String? = nil, allowIncompleteTail: Bool = false
    ) throws -> [UsageRecord] {
        try Task.checkCancellation()
        var transcript = data
        var incompleteTail = false
        if allowIncompleteTail, data.last != 0x0A {
            let start = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
            if start < data.endIndex, (try? UsageJSON.object(Data(data[start...]))) == nil {
                transcript = Data(data[..<start])
                incompleteTail = true
            }
        }
        var state = State(session: session)
        var records: [UsageRecord] = []
        var headerRead = session == nil
        for line in JSONLScanning.lines(in: transcript) {
            try Task.checkCancellation()
            let object = try UsageJSON.object(line)
            if let session, !headerRead || object["type"] as? String == "session" {
                guard object["type"] as? String == "session", object["id"] as? String == session else {
                    throw CocoaError(.coderReadCorrupt)
                }
                headerRead = true
            }
            if let record = state.record(object, path: path) { records.append(record) }
        }
        guard headerRead else { throw CocoaError(.coderReadCorrupt) }
        if incompleteTail {
            records.append(UsageRecord(
                sourceID: "openclaw", formatID: "openclaw-session", filePath: path,
                sessionID: state.session, parentSession: state.parent, kind: "incomplete-tail",
                issues: [.invalidMetadata]
            ))
        }
        return records
    }

    static func database(_ database: UsageDatabase, path: String) throws -> [UsageRecord] {
        let tables = try database.tables()
        guard tables.contains("transcript_events") else { throw CocoaError(.coderReadCorrupt) }
        let columns = try database.columns(in: "transcript_events")
        let optional = ["event_zstd", "event_utf8_bytes"].filter(columns.contains).map { ", \($0)" }.joined()
        let cold = OpenClawColdArchiveReader(database: database, path: path, tables: tables)
        var states: [String: State] = [:]
        var records: [UsageRecord] = []
        try database.rows("SELECT session_id, seq, event_json\(optional) FROM transcript_events ORDER BY session_id, seq") { row in
            guard let session = UsageJSON.string(row["session_id"]) else { throw CocoaError(.coderReadCorrupt) }
            let data: Data
            if let text = row["event_json"] as? String {
                data = Data(text.utf8)
            } else if let compressed = row["event_zstd"] as? Data {
                guard compressed.count <= 4 * 1024 * 1024 else { throw CocoaError(.coderReadCorrupt) }
                data = try UsageZstandard.decode(compressed, maximumBytes: 4 * 1024 * 1024)
                guard UsageLogNumbers.count(row["event_utf8_bytes"]) == data.count else { throw CocoaError(.coderReadCorrupt) }
            } else if let sequence = UsageLogNumbers.count(row["seq"]),
                      let restored = try cold.payload(session: session, sequence: sequence) {
                guard UsageLogNumbers.count(row["event_utf8_bytes"]) == restored.count else {
                    throw CocoaError(.coderReadCorrupt)
                }
                data = restored
            } else {
                records.append(UsageRecord(
                    sourceID: "openclaw", formatID: "openclaw-session", filePath: path, sessionID: session,
                    id: UsageLogNumbers.count(row["seq"]).map { "seq:\($0)" }, kind: "missing-payload",
                    providerID: states[session]?.provider, issues: [.invalidMetadata]
                ))
                return
            }
            var state = states[session] ?? State(session: session)
            if let record = state.record(try UsageJSON.object(data), path: path) { records.append(record) }
            states[session] = state
        }
        if tables.contains("session_transcript_archives") {
            try database.rows("SELECT session_id, encoding, archive_blob, archive_sha256 FROM session_transcript_archives") { row in
                guard let session = UsageJSON.string(row["session_id"]), let bytes = row["archive_blob"] as? Data,
                      let hash = row["archive_sha256"] as? String, OpenClawColdArchiveReader.sha256(bytes) == hash,
                      let encoding = row["encoding"] as? String, ["identity", "zstd"].contains(encoding) else {
                    throw CocoaError(.coderReadCorrupt)
                }
                let data = encoding == "zstd" ? try UsageZstandard.decode(bytes) : bytes
                records += try parseTranscript(data, path: path, session: session)
            }
        }
        return records
    }
}
