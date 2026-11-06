import Foundation

enum DeepSeekSessionParser {
    private struct Slot: Hashable { var turn: Int; var step: Int }

    static func parse(_ data: Data, path: String) throws -> [UsageRecord] {
        let file = URL(fileURLWithPath: path)
        guard let version = generation(file.lastPathComponent), version <= 4 else { throw CocoaError(.coderReadCorrupt) }
        let decoded = file.pathExtension == "zstd" ? try UsageZstandard.decodePrefix(data) : (data: data, incomplete: false)
        let complete = decoded.data.lastIndex(of: 0x0A).map { Data(decoded.data[...$0]) } ?? Data()
        var lines = JSONLScanning.lines(in: complete).makeIterator()
        guard let first = lines.next() else { throw CocoaError(.coderReadCorrupt) }
        let header = try UsageJSON.object(first)
        guard header["type"] as? String == "session",
              UsageLogNumbers.count(header["version"] as? NSNumber) == version,
              let session = UsageJSON.string(header["id"]) else { throw CocoaError(.coderReadCorrupt) }
        let seed = try inheritedSeed(header, version: version, data: complete)
        var provider: String?
        var model: String?
        var result: [UsageRecord] = []
        var settlements: [Slot: Int] = [:]
        var finished: Set<Slot> = []
        var legacyUsage: [Slot: Int] = [:]
        while let line = lines.next() {
            try Task.checkCancellation()
            let object = try UsageJSON.object(line)
            guard let type = object["type"] as? String, type != "session",
                  let payload = object["data"] as? [String: Any] else { throw CocoaError(.coderReadCorrupt) }
            let packed = version < 2 && ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(type)
            guard let seq = UsageLogNumbers.count((packed ? object["seq0"] : object["seq"]) as? NSNumber) else {
                throw CocoaError(.coderReadCorrupt)
            }
            if type == "request/header" {
                let config = (payload["header"] as? [String: Any])?["config"] as? [String: Any]
                provider = UsageJSON.string(config?["provider"])
                model = UsageJSON.string(config?["model"])
            }
            guard seq >= seed else { continue }
            let slot: Slot?
            if let turn = UsageLogNumbers.count(payload["turn"]), let step = UsageLogNumbers.count(payload["step"]) {
                slot = Slot(turn: turn, step: step)
            } else { slot = nil }
            if type == "llm/retry-started" || (version < 2 && ["llm/retry", "step/end", "turn/end"].contains(type)) {
                if let slot {
                    settlements[slot] = nil
                    finished.remove(slot)
                    legacyUsage[slot] = nil
                } else {
                    settlements.removeAll()
                    finished.removeAll()
                    legacyUsage.removeAll()
                }
            }
            var sample: [String: Any]?
            if version < 2 && (type == "assistant/chunk" || packed) {
                guard let slot else { throw CocoaError(.coderReadCorrupt) }
                if finished.remove(slot) != nil {
                    settlements[slot] = nil
                    legacyUsage[slot] = nil
                }
                let chunk = payload["chunk"] as? [String: Any]
                if chunk?["type"] as? String == "finish" { finished.insert(slot) }
                guard chunk?["type"] as? String == "usage" else { continue }
                sample = chunk?["usage"] as? [String: Any]
                if sample != nil { legacyUsage[slot] = seq }
            } else {
                guard ["assistant/message", "assistant/attempt", "compaction/summary"].contains(type) else { continue }
                sample = type == "assistant/attempt" ? streamUsage(payload["stream"])
                    : payload["usage"] as? [String: Any] ?? streamUsage(payload["stream"])
                if version < 2, type == "assistant/message", let slot {
                    if let usageSeq = legacyUsage[slot] {
                        guard let sources = object["sourceEventSeqs"] as? [Any] else { throw CocoaError(.coderReadCorrupt) }
                        if sources.isEmpty { settlements[slot] = nil } else if !references(sources, seq: usageSeq) {
                            throw CocoaError(.coderReadCorrupt)
                        }
                    }
                    legacyUsage[slot] = nil
                    finished.insert(slot)
                }
            }
            guard let usage = sample else { continue }
            let compaction = type == "compaction/summary"
            let message = payload["message"] as? [String: Any] ?? [:]
            let source = message["source"] as? [String: Any] ?? payload["source"] as? [String: Any] ?? [:]
            let replay = (source["replayState"] as? [String: Any])?["response"] as? [String: Any]
            var record = UsageRecord(
                sourceID: "dsh", formatID: "dsh-session", filePath: path, sessionID: session,
                id: UsageJSON.string(message["id"]) ?? UsageJSON.string(payload["compactionId"])
                    ?? UsageJSON.string(payload["attemptId"]) ?? "seq:\(seq)",
                kind: compaction ? "compaction" : "assistant",
                timestamp: UsageJSON.date(object["time"], milliseconds: true),
                providerID: compaction ? UsageJSON.string(payload["provider"]) : UsageJSON.string(source["provider"]) ?? provider,
                model: compaction ? UsageJSON.string(payload["model"]) : UsageJSON.string(source["model"]) ?? model,
                responseModel: compaction ? nil : UsageJSON.string(replay?["responseModel"])
            )
            UsageJSON.tokens(
                into: &record, input: usage["inputTokens"], output: usage["outputTokens"],
                cacheRead: usage["cacheReadTokens"], cacheWrite: usage["cacheWriteTokens"]
            )
            if let reasoning = usage["reasoningTokens"] {
                record.reasoningTokens = UsageLogNumbers.count(reasoning)
                if record.reasoningTokens == nil { record.issues.insert(.invalidNumbers) }
            }
            if record.timestamp == nil { record.issues.insert(.invalidMetadata) }
            if !compaction, let slot {
                if let index = settlements[slot] { result[index] = record; continue }
                settlements[slot] = result.count
            }
            result.append(record)
        }
        if decoded.incomplete || complete.count < decoded.data.count {
            result.append(UsageRecord(
                sourceID: "dsh", formatID: "dsh-session", filePath: path, sessionID: session,
                kind: "incomplete", issues: [.invalidMetadata]
            ))
        }
        return result
    }

    private static func inheritedSeed(_ header: [String: Any], version: Int, data: Data) throws -> Int {
        if version < 2 {
            guard let seed = UsageLogNumbers.count(header["seedLength"], missing: 0) else { throw CocoaError(.coderReadCorrupt) }
            return seed
        }
        guard let seeded = boolean(header["isSeeded"]) else { throw CocoaError(.coderReadCorrupt) }
        var lastMarker: Int?
        for line in JSONLScanning.lines(in: data).dropFirst() {
            try Task.checkCancellation()
            let event = try UsageJSON.object(line)
            guard event["type"] as? String == "session/end-seed",
                  boolean((event["data"] as? [String: Any])?["inherited"]) == true else { continue }
            guard let seq = UsageLogNumbers.count(event["seq"] as? NSNumber) else { throw CocoaError(.coderReadCorrupt) }
            lastMarker = seq
        }
        guard seeded == (lastMarker != nil) else { throw CocoaError(.coderReadCorrupt) }
        return lastMarker ?? 0
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func references(_ sources: [Any], seq: Int) -> Bool {
        sources.contains { source in
            if UsageLogNumbers.count(source as? NSNumber) == seq { return true }
            guard let range = source as? [Any], range.count == 2,
                  let start = UsageLogNumbers.count(range[0] as? NSNumber),
                  let end = UsageLogNumbers.count(range[1] as? NSNumber) else { return false }
            return start <= seq && seq <= end
        }
    }

    private static func streamUsage(_ value: Any?) -> [String: Any]? {
        guard let stream = value as? [[String: Any]] else { return nil }
        return stream.reversed().compactMap { row -> [String: Any]? in
            guard row["type"] as? String == "chunk", let chunk = row["chunk"] as? [String: Any],
                  chunk["type"] as? String == "usage" else { return nil }
            return chunk["usage"] as? [String: Any]
        }.first
    }

    /// 한 세션의 여러 저장 세대 중 최신 파일만 선택. 구세대로 조용히 후퇴하지 않음.
    static func isCurrentGeneration(_ url: URL) -> Bool {
        guard let generation = generation(url.lastPathComponent) else { return false }
        guard let siblings = try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) else {
            return true
        }
        let highest = siblings.compactMap(Self.generation).max() ?? generation
        guard generation == highest else { return false }
        // 같은 세대의 두 형식이 남으면 기본 압축 파일 우선.
        let compressed = url.pathExtension == "zstd"
        return compressed || !siblings.contains(url.lastPathComponent + ".zstd")
    }

    private static func generation(_ name: String) -> Int? {
        if name == "session.jsonl" || name == "session.jsonl.zstd" { return 0 }
        guard name.hasPrefix("session.v") else { return nil }
        let suffix = name.dropFirst("session.v".count)
        guard let dot = suffix.firstIndex(of: "."),
              [".jsonl", ".jsonl.zstd"].contains(String(suffix[dot...])) else { return nil }
        let digits = suffix[..<dot]
        guard let first = digits.utf8.first, (49...57).contains(first),
              digits.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(digits), value <= 9_007_199_254_740_991 else { return nil }
        return value
    }
}
