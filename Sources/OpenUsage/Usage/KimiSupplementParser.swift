import Foundation

enum KimiSupplementParser {
    static func parse(_ data: Data, path: String, work: Bool) throws -> [UsageRecord] {
        var result: [UsageRecord] = []
        var indices: [String: Int] = [:]
        let session = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let tailStart = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        let tail = data.suffix(from: tailStart)
        let completeTail = tail.isEmpty || (try? JSONSerialization.jsonObject(with: tail, options: .fragmentsAllowed)) != nil
        let complete = completeTail ? data : data.prefix(upTo: tailStart)
        for (index, line) in JSONLScanning.lines(in: complete).enumerated() {
            try Task.checkCancellation()
            guard let object = try? UsageJSON.object(line) else {
                result.append(UsageRecord(
                    sourceID: work ? "kimi-work" : "kimi-cli",
                    formatID: work ? "kimi-wire" : "kimi-legacy-wire", filePath: path, sessionID: session,
                    id: "invalid-row:\(index)", kind: "invalid", providerID: work ? "kimi" : nil,
                    issues: [.invalidMetadata]
                ))
                continue
            }
            if work && object["type"] as? String == "forked" {
                result.removeAll()
                indices.removeAll()
                continue
            }
            let usage: [String: Any]
            var record: UsageRecord
            if work {
                guard object["type"] as? String == "usage.record", let value = object["usage"] as? [String: Any] else { continue }
                usage = value
                record = UsageRecord(
                    sourceID: "kimi-work", formatID: "kimi-wire", filePath: path, sessionID: session,
                    id: UsageJSON.string(object["id"]) ?? "row:\(index)", kind: "usage",
                    timestamp: UsageJSON.date(object["time"], milliseconds: true), providerID: "kimi",
                    model: UsageJSON.string(object["model"])
                )
                UsageJSON.tokens(into: &record, input: usage["inputOther"], output: usage["output"],
                                 cacheRead: usage["inputCacheRead"], cacheWrite: usage["inputCacheCreation"])
                if usage["inputCacheRead"] == nil { record.issues.insert(.invalidMetadata) }
            } else {
                guard let message = object["message"] as? [String: Any], message["type"] as? String == "StatusUpdate",
                      let payload = message["payload"] as? [String: Any],
                      let value = payload["token_usage"] as? [String: Any] else { continue }
                usage = value
                record = UsageRecord(
                    sourceID: "kimi-cli", formatID: "kimi-legacy-wire", filePath: path, sessionID: session,
                    id: UsageJSON.string(payload["message_id"]), kind: "usage",
                    timestamp: UsageJSON.date(object["timestamp"])
                )
                UsageJSON.tokens(into: &record, input: usage["input_other"], output: usage["output"],
                                 cacheRead: usage["input_cache_read"], cacheWrite: usage["input_cache_creation"])
            }
            if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
            if let id = record.id, let previous = indices[id] {
                if result[previous].totalTokens <= record.totalTokens { result[previous] = record }
            } else {
                if let id = record.id { indices[id] = result.count }
                result.append(record)
            }
        }
        return result
    }
}
