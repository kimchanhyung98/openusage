import Foundation

enum KimiSupplementParser {
    static func parse(_ data: Data, path: String, work: Bool) throws -> [UsageRecord] {
        var result: [UsageRecord] = []
        var indices: [String: Int] = [:]
        var requests: [String: [String: (alias: String?, model: String)]] = [:]
        // 손상으로 요청 연결을 잃으면 구형 원장의 Kimi 귀속 규칙으로 되돌리지 않음.
        var routingInvalidated = false
        let session = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let tailStart = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        let tail = data.suffix(from: tailStart)
        let completeTail = tail.isEmpty || (try? JSONSerialization.jsonObject(with: tail, options: .fragmentsAllowed)) != nil
        let complete = completeTail ? data : data.prefix(upTo: tailStart)
        for (index, line) in JSONLScanning.lines(in: complete).enumerated() {
            try Task.checkCancellation()
            guard let object = try? UsageJSON.object(line), !work || object["type"] is String else {
                if work {
                    routingInvalidated = true
                    requests.removeAll()
                }
                result.append(UsageRecord(
                    sourceID: work ? "kimi-work" : "kimi-cli",
                    formatID: work ? "kimi-wire" : "kimi-legacy-wire", filePath: path, sessionID: session,
                    id: "invalid-row:\(index)", kind: "invalid", providerID: work ? "kimi" : nil,
                    issues: [.invalidMetadata]
                ))
                continue
            }
            if work && object["type"] as? String == "metadata" {
                guard let version = object["protocol_version"] as? String,
                      ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5"].contains(version)
                else { throw KimiHistoryError.unsupportedFormat }
                continue
            }
            if work && object["type"] as? String == "forked" {
                result.removeAll()
                indices.removeAll()
                requests.removeAll()
                continue
            }
            if work && object["type"] as? String == "llm.request" {
                guard let agent = object["agentId"] as? String else {
                    routingInvalidated = true
                    requests.removeAll()
                    continue
                }
                let scope: String? = switch object["kind"] as? String {
                case "loop": "turn"
                case "compaction": "session"
                default: nil
                }
                if let scope { requests[agent]?.removeValue(forKey: scope) }
                else { requests.removeValue(forKey: agent) }
                requests[agent]?.removeValue(forKey: "latest")
                let model = object["model"] as? String ?? ""
                let request = (alias: object["modelAlias"] as? String, model: model)
                requests[agent, default: [:]]["latest"] = request
                if let scope { requests[agent, default: [:]][scope] = request }
                continue
            }
            let usage: [String: Any]
            var record: UsageRecord
            if work {
                guard object["type"] as? String == "usage.record" else { continue }
                record = UsageRecord(
                    sourceID: "kimi-work", formatID: "kimi-wire", filePath: path, sessionID: session,
                    id: UsageJSON.string(object["id"]) ?? "row:\(index)", kind: "usage",
                    timestamp: UsageJSON.date(object["time"], milliseconds: true), providerID: routingInvalidated ? nil : "kimi",
                    model: UsageJSON.string(object["model"])
                )
                if let agent = object["agentId"] as? String {
                    let scoped = (object["usageScope"] as? String).flatMap { scope in
                        ["turn", "session"].contains(scope) ? requests[agent]?[scope] : nil
                    }
                    if let request = scoped ?? requests[agent]?["latest"] {
                        if let alias = request.alias, let model = object["model"] as? String,
                           alias == model, KimiUsageScanner.isKimiRoute(alias: alias, model: request.model) {
                            record.providerID = "kimi"
                        } else {
                            record.providerID = nil
                        }
                    }
                } else if requests.values.contains(where: { scopes in
                    scopes.values.contains { request in
                        guard let alias = request.alias else { return true }
                        return !KimiUsageScanner.isKimiRoute(alias: alias, model: request.model)
                    }
                }) {
                    record.providerID = nil
                }
                guard let value = object["usage"] as? [String: Any] else {
                    record.issues.insert(.invalidMetadata)
                    result.append(record)
                    continue
                }
                usage = value
                UsageJSON.tokens(into: &record, input: usage["inputOther"], output: usage["output"],
                                 cacheRead: usage["inputCacheRead"], cacheWrite: usage["inputCacheCreation"])
                if usage["inputOther"] == nil || usage["output"] == nil || usage["inputCacheRead"] == nil {
                    record.issues.insert(.invalidMetadata)
                }
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
                let oldValid = result[previous].issues.isEmpty
                let newValid = record.issues.isEmpty
                if (newValid && !oldValid) || (newValid == oldValid && result[previous].totalTokens <= record.totalTokens) {
                    result[previous] = record
                }
            } else {
                if let id = record.id { indices[id] = result.count }
                result.append(record)
            }
        }
        return result
    }
}
