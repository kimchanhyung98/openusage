import Foundation

enum QwenSessionParser {
    static func parse(_ data: Data, path: String, resources: URL) throws -> [UsageRecord] {
        let complete = data.lastIndex(of: 0x0A).map { Data(data[...$0]) } ?? Data()
        let completeRows = try JSONLScanning.lines(in: complete).map(UsageJSON.object)
        let normalized = QwenManagedJournal.journalRows(completeRows)
        let messages: [[String: Any]]
        if normalized.first?["subtype"] as? String == "managed_session_header_v1" {
            messages = try QwenManagedJournal.messages(normalized, resources: resources)
        } else {
            guard !completeRows.contains(where: { ($0["subtype"] as? String)?.hasPrefix("managed_session_") == true }) else {
                throw CocoaError(.coderReadCorrupt)
            }
            messages = try JSONLScanning.lines(in: data).map(UsageJSON.object)
        }
        return messages.compactMap { record($0, path: path) }
    }

    private static func record(_ object: [String: Any], path: String) -> UsageRecord? {
        guard object["type"] as? String == "assistant",
              let usage = object["usageMetadata"] as? [String: Any] else { return nil }
        let fork = object["forkedFrom"] as? [String: Any]
        var record = UsageRecord(
            sourceID: "qwen", formatID: "qwen-chat", filePath: path,
            sessionID: UsageJSON.string(object["sessionId"]), parentSession: UsageJSON.string(fork?["sessionId"]),
            id: UsageJSON.string(object["uuid"]), kind: "assistant",
            timestamp: UsageJSON.date(object["timestamp"]), model: UsageJSON.string(object["model"])
        )
        if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
        guard let prompt = UsageLogNumbers.count(usage["promptTokenCount"], missing: 0),
              let output = UsageLogNumbers.count(usage["candidatesTokenCount"], missing: 0),
              let reasoning = UsageLogNumbers.count(usage["thoughtsTokenCount"], missing: 0),
              let cache = UsageLogNumbers.count(usage["cachedContentTokenCount"], missing: 0), cache <= prompt,
              let base = UsageLogNumbers.sum(prompt, output),
              let expanded = UsageLogNumbers.sum(prompt, output, reasoning),
              let reported = UsageLogNumbers.count(usage["totalTokenCount"], missing: 0) else {
            record.issues.insert(.invalidNumbers)
            return record
        }
        let included = reported == base || (reported == 0 && output > 0)
        if reasoning > 0, !included, reported != expanded { record.issues.insert(.invalidMetadata) }
        guard let combined = UsageLogNumbers.sum(output, included ? 0 : reasoning) else {
            record.issues.insert(.invalidNumbers)
            return record
        }
        UsageJSON.tokens(into: &record, input: prompt - cache, output: combined, cacheRead: cache,
                         total: reported > 0 ? reported : nil)
        record.reasoningTokens = reasoning
        return record
    }
}
