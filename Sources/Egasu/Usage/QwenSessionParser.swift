import Foundation

enum QwenSessionParser {
    /// 관리형 원장은 외부 리소스를 매번 검증. 헤더 판별이 불확실하면 기존 파싱 경로 사용.
    static func canReuseCachedFile(at path: String) -> Bool {
        guard !Task.isCancelled, let file = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return false }
        defer { try? file.close() }
        guard let prefix = try? file.read(upToCount: 64 * 1024) else { return false }
        for line in JSONLScanning.lines(in: prefix) {
            guard !Task.isCancelled, let object = try? UsageJSON.object(line) else { return false }
            let subtype = object["subtype"] as? String
            if subtype == "session_execution_engine" { continue }
            return subtype?.hasPrefix("managed_session_") != true
        }
        return false
    }

    static func parse(_ data: Data, path: String, resources: URL) throws -> [UsageRecord] {
        try Task.checkCancellation()
        let complete = data.lastIndex(of: 0x0A).map { Data(data[...$0]) } ?? Data()
        var completeRows: [[String: Any]] = []
        for line in JSONLScanning.lines(in: complete) {
            try Task.checkCancellation()
            completeRows.append(try UsageJSON.object(line))
        }
        let normalized = QwenManagedJournal.journalRows(completeRows)
        let messages: [[String: Any]]
        if normalized.first?["subtype"] as? String == "managed_session_header_v1" {
            messages = try QwenManagedJournal.messages(normalized, resources: resources)
        } else {
            for row in completeRows {
                try Task.checkCancellation()
                guard (row["subtype"] as? String)?.hasPrefix("managed_session_") != true else {
                    throw CocoaError(.coderReadCorrupt)
                }
            }
            var ordinaryMessages = completeRows
            let tail = Data(data.dropFirst(complete.count))
            if !tail.isEmpty {
                try Task.checkCancellation()
                do {
                    ordinaryMessages.append(try UsageJSON.object(tail))
                } catch {
                    if completeRows.isEmpty { throw error }
                }
            }
            messages = ordinaryMessages
        }
        var records: [UsageRecord] = []
        for message in messages {
            try Task.checkCancellation()
            if let parsed = record(message, path: path) { records.append(parsed) }
        }
        return records
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
        if reasoning == 0, reported > 0, reported != base,
           usage["promptTokenCount"] != nil || usage["candidatesTokenCount"] != nil {
            record.issues.insert(.invalidMetadata)
        }
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
