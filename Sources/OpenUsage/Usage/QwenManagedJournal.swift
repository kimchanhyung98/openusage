import CryptoKit
import Foundation

/// 관리형 원장의 commit 경계와 불변 리소스 검증. 본문은 파싱 중에만 유지.
enum QwenManagedJournal {
    static func journalRows(_ rows: [[String: Any]]) -> [[String: Any]] {
        Array(rows.drop(while: { $0["subtype"] as? String == "session_execution_engine" }))
    }

    static func messages(_ input: [[String: Any]], resources: URL) throws -> [[String: Any]] {
        let rows = journalRows(input)
        let canonical = try QwenCanonicalJSON().encode
        guard let header = rows.first?["managedSession"] as? [String: Any],
              header["engine"] as? String == "managed",
              let sessionKey = header["sessionKey"] as? [String: Any],
              let sessionID = UsageJSON.string(sessionKey["sessionId"]),
              let definition = header["definitionRef"] as? [String: Any],
              let rootSnapshot = header["rootSnapshotRef"] as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
        let root = try directory(resources, segments: [sessionID])
        _ = try resource(definition, root: root)
        _ = try resource(rootSnapshot, root: root)
        if let value = header["baseTranscriptProof"] {
            guard let proof = value as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            _ = try resource(proof, root: root)
        }
        let reader: String
        if let value = header["minimumReader"] {
            guard let version = value as? String else { throw CocoaError(.coderReadCorrupt) }
            reader = version
        } else {
            reader = "managed-session/1"
        }
        let logical: [[String: Any]]
        if reader == "managed-session/2" {
            logical = try restore(rows, root: root, sessionKey: sessionKey, canonical: canonical)
        } else if reader == "managed-session/1" {
            logical = rows
        } else { throw CocoaError(.coderReadCorrupt) }
        let committed = try committedEvents(logical, sessionKey: sessionKey, canonical: canonical)
        return try committed.events.compactMap { event in
            guard event["kind"] as? String == "message.committed" else { return nil }
            guard let payload = event["payload"] as? [String: Any],
                  let ref = payload["contentRef"] as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            let bytes = try message(ref, root: root)
            let record = try UsageJSON.object(bytes)
            guard UsageJSON.string(record["uuid"]) == UsageJSON.string(payload["messageId"]),
                  UsageJSON.string(record["sessionId"]) == sessionID else { throw CocoaError(.coderReadCorrupt) }
            return record
        }
    }

    private struct Committed {
        var events: [[String: Any]] = []
        var sequence = 0
        var digest: String?
        var lastUUID: String?
    }

    private static func committedEvents(
        _ rows: [[String: Any]], sessionKey: [String: Any], canonical: (Any) throws -> Data
    ) throws -> Committed {
        var result = Committed()
        var pending: [[String: Any]] = []
        let key = try canonical(sessionKey)
        for row in rows.dropFirst() {
            try Task.checkCancellation()
            switch row["subtype"] as? String {
            case "managed_session_event_v1":
                guard let event = row["managedSession"] as? [String: Any],
                      let eventKey = event["sessionKey"] as? [String: Any], try canonical(eventKey) == key,
                      UsageLogNumbers.count(event["sequence"]) == result.sequence + pending.count + 1 else {
                    throw CocoaError(.coderReadCorrupt)
                }
                pending.append(event)
            case "managed_session_commit_v1":
                guard let commit = row["managedSession"] as? [String: Any],
                      UsageLogNumbers.count(commit["eventCount"]) == pending.count,
                      UsageLogNumbers.count(commit["firstSequence"]) == result.sequence + 1,
                      let last = UsageLogNumbers.count(commit["lastSequence"]), last == result.sequence + pending.count,
                      UsageJSON.string(commit["eventsDigest"]) == digest(try canonical(pending)),
                      UsageJSON.string(commit["previousCommitDigest"]) == result.digest else {
                    throw CocoaError(.coderReadCorrupt)
                }
                result.events += pending
                pending.removeAll()
                result.sequence = last
                result.digest = digest(try canonical(commit))
                result.lastUUID = UsageJSON.string(row["uuid"])
            default: break
            }
        }
        return result
    }

    private static func restore(
        _ rows: [[String: Any]], root: URL, sessionKey: [String: Any], canonical: (Any) throws -> Data
    ) throws -> [[String: Any]] {
        guard rows.count > 1, rows[1]["subtype"] as? String == "managed_session_snapshot_base_v1",
              let base = rows[1]["managedSessionSnapshot"] as? [String: Any],
              base["format"] as? String == "qwen-managed-local-journal-snapshot/1",
              let key = base["sessionKey"] as? [String: Any], try canonical(key) == canonical(sessionKey),
              let ref = base["manifest"] as? [String: Any],
              ref["kind"] as? String == "managed-local-journal-snapshot", ref["resourceId"] as? String == ref["digest"] as? String
        else { throw CocoaError(.coderReadCorrupt) }
        let manifest = try UsageJSON.object(resource(ref, root: root))
        guard let pages = manifest["pages"] as? [[String: Any]],
              let references = manifest["resources"] as? [[String: Any]],
              let manifestKey = manifest["sessionKey"] as? [String: Any], try canonical(manifestKey) == canonical(sessionKey)
        else { throw CocoaError(.coderReadCorrupt) }
        for reference in references {
            try Task.checkCancellation()
            _ = try resource(reference, root: root)
        }
        var data = Data()
        for page in pages {
            guard page["kind"] as? String == "managed-local-journal-snapshot-page" else { throw CocoaError(.coderReadCorrupt) }
            let bytes = try resource(page, root: root)
            guard data.count <= 256 * 1024 * 1024 - bytes.count else { throw CocoaError(.coderReadCorrupt) }
            data.append(bytes)
        }
        guard UsageLogNumbers.count(manifest["byteLength"]) == data.count,
              manifest["digest"] as? String == digest(data) else { throw CocoaError(.coderReadCorrupt) }
        let prefix = journalRows(try JSONLScanning.lines(in: data).map(UsageJSON.object))
        guard (prefix.first?["managedSession"] as? [String: Any])?["minimumReader"] as? String != "managed-session/2" else {
            throw CocoaError(.coderReadCorrupt)
        }
        let committed = try committedEvents(prefix, sessionKey: sessionKey, canonical: canonical)
        guard UsageLogNumbers.count(manifest["committedSequence"]) == committed.sequence,
              UsageJSON.string(manifest["lastCommitDigest"]) == committed.digest,
              UsageJSON.string(manifest["lastRecordUuid"]) == committed.lastUUID else { throw CocoaError(.coderReadCorrupt) }
        return prefix + rows.dropFirst(2)
    }

    private static func message(_ ref: [String: Any], root: URL) throws -> Data {
        if ref["kind"] as? String == "managed-message" { return try resource(ref, root: root) }
        guard ref["kind"] as? String == "managed-message-chunks",
              let parts = try UsageJSON.object(resource(ref, root: root))["parts"] as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        var data = Data()
        for part in parts {
            guard part["kind"] as? String == "managed-message-part" else { throw CocoaError(.coderReadCorrupt) }
            let bytes = try resource(part, root: root)
            guard data.count <= 256 * 1024 * 1024 - bytes.count else { throw CocoaError(.coderReadCorrupt) }
            data.append(bytes)
        }
        return data
    }

    private static func resource(_ ref: [String: Any], root: URL) throws -> Data {
        guard let kind = UsageJSON.string(ref["kind"]), let id = UsageJSON.string(ref["resourceId"]),
              UsageLogNumbers.count(ref["schemaVersion"]) == 1,
              let length = UsageLogNumbers.count(ref["byteLength"]), length <= 16 * 1024 * 1024 else {
            throw CocoaError(.coderReadCorrupt)
        }
        let url = try directory(root, segments: [kind, id])
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: length + 1) ?? Data()
        guard data.count == length, ref["digest"] as? String == digest(data) else { throw CocoaError(.coderReadCorrupt) }
        return data
    }

    private static func directory(_ root: URL, segments: [String]) throws -> URL {
        guard segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\") }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        let url = segments.reduce(root) { $0.appendingPathComponent($1) }.resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw CocoaError(.coderReadCorrupt) }
        return url
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
