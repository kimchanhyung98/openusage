import Foundation

enum DevinDesktopParser {
    static func parse(_ data: Data, path: String) throws -> [UsageRecord] {
        var result: [UsageRecord] = []
        let session = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        for (index, line) in JSONLScanning.lines(in: data).enumerated() {
            try Task.checkCancellation()
            let object = try UsageJSON.object(line)
            guard let event = object["notification"] as? [String: Any], event["sessionUpdate"] as? String == "usage_update" else {
                continue
            }
            let provider = UsageJSON.string(object["providerId"])
            let metadata = event["metadata"] as? [String: Any]
            let meta = event["_meta"] as? [String: Any]
            let requestID = UsageJSON.string(metadata?["request_id"])
            let timestamp = UsageJSON.date(meta?["cognition.ai/timestamp"], milliseconds: true)
                ?? UsageJSON.date(metadata?["created_at"] ?? event["timestamp"] ?? object["timestamp"])
            var record = UsageRecord(
                sourceID: "devin-desktop", formatID: "devin-acp", granularity: .aggregate, filePath: path,
                sessionID: session, id: "event:\(index)" + (requestID.map { ":\($0)" } ?? ""), kind: "usage-update",
                timestamp: timestamp,
                providerID: provider == "devin-cli" ? "devin" : nil,
                model: UsageJSON.string(metadata?["generation_model"] ?? meta?["cognition.ai/model"]),
                upstreamProvider: provider, issues: [.unresolvedMirror]
            )
            // 요청·누적 단위가 미확인인 관찰값. 캐시 차감·이벤트 합산·요청 ID 중복 제거에 사용하지 않음.
            if let usage = metadata?["metrics"] as? [String: Any] {
                UsageJSON.tokens(into: &record, input: usage["input_tokens"], output: usage["output_tokens"],
                                 cacheRead: usage["cache_read_tokens"], cacheWrite: usage["cache_creation_tokens"], total: 0)
            } else if let meta, meta["cognition.ai/inputTokens"] != nil {
                UsageJSON.tokens(into: &record, input: meta["cognition.ai/inputTokens"], output: meta["cognition.ai/outputTokens"],
                                 cacheRead: meta["cognition.ai/cachedReadTokens"], cacheWrite: meta["cognition.ai/cachedWriteTokens"], total: 0)
            }
            result.append(record)
        }
        return result
    }
}
