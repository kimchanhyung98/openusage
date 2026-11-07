import CryptoKit
import Foundation

/// 이벤트 캐시와 별도로 매 수집 시 fork 계보 갱신.
struct JunieUsageCollector: UsageCollecting {
    private let files: UsageFileCollector

    init(root: URL, scanner: IncrementalJSONLScanner<UsageRecord>? = nil) {
        files = UsageFileCollector(
            sourceID: "junie", roots: [root], version: 4, scanner: scanner,
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
                if Task.isCancelled { return nil }
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
        let completeEnd = data.last == 0x0A ? data.endIndex : (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? data.startIndex)
        let parseData: Data
        if completeEnd < data.endIndex, (try? UsageJSON.object(data[completeEnd..<data.endIndex])) == nil {
            parseData = data.prefix(upTo: completeEnd)
        } else {
            parseData = data
        }
        for line in JSONLScanning.lines(in: parseData) {
            try Task.checkCancellation()
            let object: [String: Any]
            do {
                object = try UsageJSON.object(line)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.append(UsageRecord(
                    sourceID: "junie", formatID: "junie-events", filePath: path, sessionID: session,
                    kind: "invalid-line", issues: [.invalidMetadata]
                ))
                continue
            }
            guard let event = object["event"] as? [String: Any],
                  let agent = event["agentEvent"] as? [String: Any],
                  agent["kind"] as? String == "LlmResponseMetadataEvent",
                  !["AgentStateUpdatedEvent", "AgentCurrentStatusUpdatedEvent", "AgentPatchCreatedEvent"]
                    .contains(object["kind"] as? String ?? ""),
                  let usages = agent["modelUsage"] as? [Any] else { continue }
            let date = UsageJSON.date(object["timestampMs"], milliseconds: true)
            for (index, value) in usages.enumerated() {
                guard let usage = value as? [String: Any] else {
                    result.append(UsageRecord(
                        sourceID: "junie", formatID: "junie-events", filePath: path, sessionID: session,
                        id: "invalid:\(index)", kind: "model-usage", timestamp: date, issues: [.invalidMetadata]
                    ))
                    continue
                }
                var record = UsageRecord(
                    sourceID: "junie", formatID: "junie-events", filePath: path, sessionID: session,
                    kind: "model-usage", timestamp: date, providerID: UsageJSON.string(usage["provider"]),
                    model: UsageJSON.string(usage["model"]), costOrigin: .estimated, zeroCostIsUnknown: true
                )
                if date == nil { record.issues.insert(.invalidMetadata) }
                let tokenAliases = [
                    ["inputTokens", "input"], ["outputTokens", "output"],
                    ["cacheInputTokens", "cacheReadInputTokens", "cacheRead"],
                    ["cacheCreateTokens", "cacheCreationInputTokens", "cacheWrite"]
                ]
                let tokenValues = tokenAliases.map { keys in keys.compactMap { usage[$0] }.first { !($0 is NSNull) } }
                if tokenValues.contains(where: { $0 != nil }) {
                    UsageJSON.tokens(
                        into: &record, input: tokenValues[0], output: tokenValues[1],
                        cacheRead: tokenValues[2], cacheWrite: tokenValues[3]
                    )
                } else {
                    record.issues.insert(.invalidMetadata)
                }
                if let reasoning = ["reasoningTokens", "reasoningOutputTokens", "thinkingTokens"]
                    .compactMap({ usage[$0] }).first(where: { !($0 is NSNull) }) {
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
