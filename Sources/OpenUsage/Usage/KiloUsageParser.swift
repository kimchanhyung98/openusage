import Foundation

enum KiloUsageParser {
    static func database(_ database: UsageDatabase, path: String) throws -> [UsageRecord] {
        let tables = try database.tables()
        guard tables.contains("message") || tables.contains("session_message") else { throw CocoaError(.coderReadCorrupt) }
        var result: [UsageRecord] = []
        var stepMessages: Set<String> = []
        var seenMessages: Set<String> = []
        if tables.contains("part") && tables.contains("message") {
            try database.rows("""
                SELECT p.id, p.message_id, p.session_id, p.time_created, p.data,
                       m.data AS message_data
                FROM part p JOIN message m ON p.message_id=m.id AND p.session_id=m.session_id
                WHERE CASE WHEN json_valid(p.data) THEN json_extract(p.data, '$.type')='step-finish' ELSE 1 END
                ORDER BY p.time_created, p.id
                """) { row in
                guard let payload = json(row["data"], row: row, path: path, into: &result),
                      payload["tokens"] != nil || payload["cost"] != nil else { return }
                let message: [String: Any]?
                do {
                    guard let text = row["message_data"] as? String else { throw CocoaError(.coderReadCorrupt) }
                    message = try UsageJSON.object(Data(text.utf8))
                } catch { message = nil }
                var record = base(row, payload: message ?? [:], path: path, kind: "step")
                if message == nil { record.issues.insert(.invalidMetadata) }
                record.timestamp = UsageJSON.date((payload["time"] as? [String: Any])?["end"], milliseconds: true)
                    ?? record.timestamp
                record.responseID = UsageJSON.string(payload["generationID"])
                    ?? UsageJSON.string(payload["vercelID"]).map { "kilo:vercel:\($0)" }
                let routedModel = payload["model"] as? [String: Any]
                record.responseModel = UsageJSON.string(routedModel?["modelID"]) ?? UsageJSON.string(payload["model"])
                record.upstreamProvider = UsageJSON.string(routedModel?["providerID"])
                appendTokens(payload["tokens"], into: &record)
                UsageJSON.cost(payload["cost"], into: &record)
                if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
                result.append(record)
                if let id = UsageJSON.string(row["message_id"]) { stepMessages.insert(id) }
            }
        }
        if tables.contains("message") {
            try database.rows("SELECT id, session_id, time_created, data FROM message ORDER BY time_created, id") { row in
                guard let payload = json(row["data"], row: row, path: path, into: &result),
                      payload["role"] as? String == "assistant",
                      let id = UsageJSON.string(row["id"]), !stepMessages.contains(id),
                      payload["tokens"] != nil || payload["cost"] != nil else { return }
                var record = base(row, payload: payload, path: path, kind: "assistant")
                appendTokens(payload["tokens"], into: &record)
                UsageJSON.cost(payload["cost"], into: &record)
                guard !isImportStub(record) else { return }
                record.granularity = .aggregate
                // 메시지 합계에는 하위 agent 비용이 포함될 수 있어 직접 호출 원장으로 가산하지 않음.
                record.issues.insert(.unresolvedMirror)
                result.append(record)
                seenMessages.insert(id)
            }
        }
        if tables.contains("session_message") {
            try database.rows("SELECT id, session_id, seq, time_created, data FROM session_message WHERE type='assistant' ORDER BY seq") { row in
                guard let id = UsageJSON.string(row["id"]), !stepMessages.contains(id), !seenMessages.contains(id) else { return }
                guard let payload = json(row["data"], row: row, path: path, into: &result),
                      payload["tokens"] != nil || payload["cost"] != nil else { return }
                var record = base(row, payload: payload, path: path, kind: "assistant")
                let model = payload["model"] as? [String: Any]
                record.model = UsageJSON.string(model?["id"])
                record.providerID = UsageJSON.string(model?["providerID"])
                appendTokens(payload["tokens"], into: &record)
                UsageJSON.cost(payload["cost"], into: &record)
                // seq 없는 구형 호환 행은 요청 경계 미확정.
                record.granularity = row["seq"] == nil ? .aggregate : .request
                if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
                if !isImportStub(record) { result.append(record) }
            }
        }
        return result
    }

    static func legacy(_ data: Data, path: String) throws -> [UsageRecord] {
        guard let messages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let session = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return messages.enumerated().compactMap { index, message in
            guard message["type"] as? String == "say", message["say"] as? String == "api_req_started",
                  let text = message["text"] as? String else { return nil }
            var record = UsageRecord(
                sourceID: "kilocode", formatID: "kilo-legacy", filePath: path, sessionID: session,
                id: UsageJSON.string(message["id"]) ?? "row:\(index)", kind: "request",
                timestamp: UsageJSON.date(message["ts"], milliseconds: true),
                costOrigin: .estimated, zeroCostIsUnknown: true
            )
            let usage: [String: Any]
            do { usage = try UsageJSON.object(Data(text.utf8)) } catch {
                record.issues.insert(.invalidMetadata)
                return record
            }
            guard usage["tokensIn"] != nil || usage["tokensOut"] != nil || usage["cost"] != nil else { return nil }
            record.model = UsageJSON.string((usage["modelInfo"] as? [String: Any])?["id"])
            if record.timestamp == nil || usage["usageMissing"] as? Bool == true { record.issues.insert(.invalidMetadata) }
            if let input = UsageLogNumbers.count(usage["tokensIn"], missing: 0),
               let read = UsageLogNumbers.count(usage["cacheReads"], missing: 0),
               let write = UsageLogNumbers.count(usage["cacheWrites"], missing: 0),
               let cached = UsageLogNumbers.sum(read, write) {
                let inclusive = usage["apiProtocol"] as? String == "openai"
                    || (record.timestamp?.timeIntervalSince1970 ?? 0) >= 1_762_041_600
                if inclusive && cached > input { record.issues.insert(.invalidNumbers) } else {
                    UsageJSON.tokens(into: &record, input: input - (inclusive ? cached : 0), output: usage["tokensOut"],
                                     cacheRead: read, cacheWrite: write)
                }
            } else { record.issues.insert(.invalidNumbers) }
            UsageJSON.cost(usage["cost"], into: &record)
            return record
        }
    }

    private static func base(_ row: [String: Any], payload: [String: Any], path: String, kind: String) -> UsageRecord {
        let time = payload["time"] as? [String: Any]
        return UsageRecord(
            sourceID: "kilo", formatID: "kilo-db", filePath: path, sessionID: UsageJSON.string(row["session_id"]),
            id: UsageJSON.string(row["id"]), kind: kind,
            timestamp: UsageJSON.date(time?["created"] ?? row["time_created"], milliseconds: true),
            providerID: UsageJSON.string(payload["providerID"]), model: UsageJSON.string(payload["modelID"]),
            costOrigin: .estimated, zeroCostIsUnknown: true
        )
    }

    private static func appendTokens(_ value: Any?, into record: inout UsageRecord) {
        let usage: [String: Any]
        if let value {
            guard let object = value as? [String: Any] else { record.issues.insert(.invalidNumbers); return }
            usage = object
        } else { usage = [:] }
        let cache: [String: Any]
        if let value = usage["cache"] {
            guard let object = value as? [String: Any] else { record.issues.insert(.invalidNumbers); return }
            cache = object
        } else { cache = [:] }
        guard let reasoning = UsageLogNumbers.count(usage["reasoning"], missing: 0),
              let output = UsageLogNumbers.count(usage["output"], missing: 0),
              let combined = UsageLogNumbers.sum(output, reasoning) else { record.issues.insert(.invalidNumbers); return }
        UsageJSON.tokens(into: &record, input: usage["input"], output: combined, cacheRead: cache["read"], cacheWrite: cache["write"])
        record.reasoningTokens = reasoning
    }

    private static func isImportStub(_ record: UsageRecord) -> Bool {
        record.model == "legacy" && record.providerID == "legacy" && record.totalTokens == 0
            && record.recordedCostUSD == 0 && record.issues.isEmpty
    }

    private static func json(
        _ value: Any?, row: [String: Any], path: String, into records: inout [UsageRecord]
    ) -> [String: Any]? {
        do {
            guard let text = value as? String else { throw CocoaError(.coderReadCorrupt) }
            return try UsageJSON.object(Data(text.utf8))
        } catch {
            var record = base(row, payload: [:], path: path, kind: "invalid")
            record.issues.insert(.invalidMetadata)
            records.append(record)
            return nil
        }
    }
}
