import CryptoKit
import Foundation

/// 이벤트 캐시와 별도로 매 수집 시 fork 계보 갱신.
struct JunieUsageCollector: UsageCollecting {
    private let files: UsageFileCollector

    init(root: URL, scanner: IncrementalJSONLScanner<UsageRecord>? = nil) {
        files = UsageFileCollector(
            sourceID: "junie", roots: [root], version: 2, scanner: scanner,
            includeFile: { $0.lastPathComponent == "events.jsonl" }, parse: JunieSessionParser.parse
        )
    }

    func collect(since: Date) async -> UsageCollection? {
        guard var collection = await files.collect(since: since), !Task.isCancelled else { return nil }
        let sessions = Dictionary(grouping: collection.records.indices) { collection.records[$0].filePath }
        for (path, indices) in sessions {
            guard !Task.isCancelled else { return nil }
            guard let path else { continue }
            do {
                let parent = try JunieSessionParser.parentSession(path: path)
                for index in indices { collection.records[index].parentSession = parent }
            } catch {
                for index in indices { collection.records[index].issues.insert(.invalidMetadata) }
                collection.sources[0].failedStores += 1
                AppDiagnostics.record(
                    .historyScan, result: .degraded, providerID: "junie", error: error,
                    localContext: "source=junie; invalid_lineage=1"
                )
            }
        }
        return Task.isCancelled ? nil : collection
    }

    func flushCache() async { await files.flushCache() }
}

enum JunieSessionParser {
    static func parse(_ data: Data, path: String) throws -> [UsageRecord] {
        var result: [UsageRecord] = []
        let session = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        for line in JSONLScanning.lines(in: data) {
            try Task.checkCancellation()
            let object = try UsageJSON.object(line)
            guard let event = object["event"] as? [String: Any],
                  let agent = event["agentEvent"] as? [String: Any],
                  agent["kind"] as? String == "LlmResponseMetadataEvent",
                  !["AgentStateUpdatedEvent", "AgentCurrentStatusUpdatedEvent", "AgentPatchCreatedEvent"]
                    .contains(object["kind"] as? String ?? ""),
                  let usages = agent["modelUsage"] as? [[String: Any]] else { continue }
            let date = UsageJSON.date(object["timestampMs"], milliseconds: true)
            for (index, usage) in usages.enumerated() {
                var record = UsageRecord(
                    sourceID: "junie", formatID: "junie-events", filePath: path, sessionID: session,
                    kind: "model-usage", timestamp: date, providerID: UsageJSON.string(usage["provider"]),
                    model: UsageJSON.string(usage["model"]), costOrigin: .estimated, zeroCostIsUnknown: true
                )
                if date == nil { record.issues.insert(.invalidMetadata) }
                let tokenValues: [Any?] = [
                    usage["inputTokens"] ?? usage["input"], usage["outputTokens"] ?? usage["output"],
                    usage["cacheInputTokens"] ?? usage["cacheReadInputTokens"] ?? usage["cacheRead"],
                    usage["cacheCreateTokens"] ?? usage["cacheCreationInputTokens"] ?? usage["cacheWrite"]
                ].map { $0 is NSNull ? nil : $0 }
                if tokenValues.contains(where: { $0 != nil }) {
                    UsageJSON.tokens(
                        into: &record, input: tokenValues[0], output: tokenValues[1],
                        cacheRead: tokenValues[2], cacheWrite: tokenValues[3]
                    )
                } else {
                    record.issues.insert(.invalidMetadata)
                }
                if let reasoning = usage["reasoningTokens"] ?? usage["reasoningOutputTokens"] ?? usage["thinkingTokens"] {
                    record.reasoningTokens = UsageLogNumbers.count(reasoning)
                    if record.reasoningTokens == nil { record.issues.insert(.invalidNumbers) }
                }
                UsageJSON.cost(usage["cost"] is NSNull ? nil : usage["cost"], into: &record)
                if date != nil {
                    let identity = try JSONSerialization.data(withJSONObject: usage, options: [.sortedKeys])
                    record.id = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined() + ":\(index)"
                }
                result.append(record)
            }
        }
        return result
    }

    static func parentSession(path: String) throws -> String? {
        let session = URL(fileURLWithPath: path).deletingLastPathComponent()
        let data: Data
        do {
            data = try Data(contentsOf: session.appendingPathComponent("session_metadata.json"))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return nil
        }
        let object = try UsageJSON.object(data)
        guard let value = object["forkedFrom"], !(value is NSNull) else { return nil }
        guard let parent = value as? String, !parent.isEmpty, !parent.contains("/"),
              parent != ".", parent != "..", parent != session.lastPathComponent else {
            throw CocoaError(.coderReadCorrupt)
        }
        return parent
    }
}
