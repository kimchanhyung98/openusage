import Foundation

enum KiroLegacyUsageParser {
    static func session(_ data: Data, path: String) throws -> [UsageRecord] {
        let object = try UsageJSON.object(data)
        guard let state = object["session_state"] as? [String: Any],
              let metadata = state["conversation_metadata"] as? [String: Any],
              let turns = metadata["user_turn_metadatas"] as? [[String: Any]] else { return [] }
        let model = ((state["rts_model_state"] as? [String: Any])?["model_info"] as? [String: Any])?["model_id"]
        return turns.enumerated().map { index, turn in
            let ids = turn["message_ids"] as? [String] ?? []
            var record = base(path: path, session: UsageJSON.string(object["session_id"]),
                              id: ids.isEmpty ? "turn:\(index)" : ids.joined(separator: ":"), model: model)
            record.timestamp = UsageJSON.date(turn["end_timestamp"])
            if turn["input_token_count"] != nil || turn["output_token_count"] != nil {
                UsageJSON.tokens(
                    into: &record, input: turn["input_token_count"], output: turn["output_token_count"],
                    cacheRead: turn["cache_read_input_token_count"], cacheWrite: turn["cache_write_input_token_count"]
                )
            }
            credits(turn["metering_usage"], into: &record)
            if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
            return record
        }
    }

    static func database(_ database: UsageDatabase, path: String) throws -> [UsageRecord] {
        guard try database.tables().contains("conversations_v2") else { throw CocoaError(.coderReadCorrupt) }
        var result: [UsageRecord] = []
        try database.rows("SELECT conversation_id, value FROM conversations_v2") { row in
            guard let raw = row["value"] as? String else { throw CocoaError(.coderReadCorrupt) }
            let object = try UsageJSON.object(Data(raw.utf8))
            guard let history = object["history"] as? [[String: Any]] else { return }
            let model = (object["model_info"] as? [String: Any])?["model_id"]
            for (index, turn) in history.enumerated() {
                guard let metadata = turn["request_metadata"] as? [String: Any] else { continue }
                let usage = metadata["token_usage"] as? [String: Any] ?? metadata["usage"] as? [String: Any] ?? metadata
                var record = base(path: path, session: UsageJSON.string(row["conversation_id"]), id: "turn:\(index)", model: model)
                record.timestamp = UsageJSON.date(metadata["request_start_timestamp_ms"] ?? metadata["stream_end_timestamp_ms"], milliseconds: true)
                if usage["input_tokens"] != nil || usage["output_tokens"] != nil {
                    UsageJSON.tokens(into: &record, input: usage["input_tokens"], output: usage["output_tokens"],
                                     cacheRead: usage["cache_read_input_tokens"], cacheWrite: usage["cache_write_input_tokens"])
                }
                credits((turn["user_turn_metadata"] as? [String: Any])?["usage_info"], into: &record)
                if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
                if record.tokens != nil || record.recordedCostUSD != nil || record.issues.contains(.invalidNumbers) {
                    result.append(record)
                }
            }
            if let usage = (object["user_turn_metadata"] as? [String: Any])?["usage_info"] {
                var record = base(path: path, session: UsageJSON.string(row["conversation_id"]),
                                  id: "unattributed-credits", model: model)
                record.kind = "unattributed-credits"
                credits(usage, into: &record)
                if record.recordedCostUSD != nil || !record.issues.isEmpty {
                    record.issues.insert(.invalidMetadata)
                    result.append(record)
                }
            }
        }
        return result
    }

    private static func base(path: String, session: String?, id: String, model: Any?) -> UsageRecord {
        UsageRecord(sourceID: "kiro-cli", formatID: "kiro-v2", granularity: .aggregate,
                    filePath: path, sessionID: session, id: id, kind: "turn", providerID: "kiro",
                    model: UsageJSON.string(model), costOrigin: .creditEquivalent)
    }

    private static func credits(_ value: Any?, into record: inout UsageRecord) {
        guard let value else { return }
        guard let entries = value as? [[String: Any]] else { record.issues.insert(.invalidNumbers); return }
        guard !entries.isEmpty else { return }
        var total = 0.0
        for entry in entries {
            guard ["credit", "credits"].contains((entry["unit"] as? String ?? "").lowercased()),
                  let amount = ProviderParse.number(entry["value"]), amount >= 0,
                  (total + amount).isFinite else { record.issues.insert(.invalidNumbers); return }
            total += amount
        }
        UsageJSON.cost(total * 0.04, into: &record)
    }
}
