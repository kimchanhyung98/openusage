import Foundation

enum GeminiSessionParser {
    static func parse(_ data: Data, path: String) throws -> [UsageRecord] {
        var session: String?
        var records: [UsageRecord] = []
        var indices: [String: Int] = [:]
        func consume(_ object: [String: Any]) {
            if let id = UsageJSON.string(object["sessionId"]) { session = id }
            if let messages = object["messages"] as? [[String: Any]] {
                for message in messages { consume(message) }
            }
            if let set = object["$set"] as? [String: Any] { consume(set) }
            guard object["type"] as? String == "gemini", let usage = object["tokens"] as? [String: Any] else { return }
            var record = UsageRecord(
                sourceID: "gemini", formatID: "gemini-chat", filePath: path, sessionID: session,
                id: UsageJSON.string(object["id"]), kind: "message", timestamp: UsageJSON.date(object["timestamp"]),
                model: UsageJSON.string(object["model"])
            )
            if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
            if let input = UsageLogNumbers.count(usage["input"], missing: 0),
               let output = UsageLogNumbers.count(usage["output"], missing: 0),
               let cache = UsageLogNumbers.count(usage["cached"], missing: 0), cache <= input,
               let reasoning = UsageLogNumbers.count(usage["thoughts"], missing: 0),
               let tool = UsageLogNumbers.count(usage["tool"], missing: 0),
               let combinedOutput = UsageLogNumbers.sum(output, reasoning),
               let inputWithTool = UsageLogNumbers.sum(input, tool),
               let baseTotal = UsageLogNumbers.sum(input, output, reasoning, tool),
               let total = UsageLogNumbers.count(usage["total"], missing: baseTotal) {
                UsageJSON.tokens(
                    into: &record, input: inputWithTool - cache, output: combinedOutput,
                    cacheRead: cache, total: total
                )
                record.reasoningTokens = reasoning
            } else {
                record.issues.insert(.invalidNumbers)
            }
            if let id = record.id, let index = indices[id] {
                records[index] = record
            } else {
                if let id = record.id { indices[id] = records.count }
                records.append(record)
            }
        }
        if URL(fileURLWithPath: path).pathExtension == "json" {
            consume(try UsageJSON.object(data))
        } else {
            for line in JSONLScanning.lines(in: data) {
                try Task.checkCancellation()
                do {
                    consume(try UsageJSON.object(line))
                } catch {
                    records.append(UsageRecord(
                        sourceID: "gemini", formatID: "gemini-chat", filePath: path, sessionID: session,
                        kind: "invalid-line", issues: [.invalidMetadata]
                    ))
                }
            }
        }
        return records
    }
}
