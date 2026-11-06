import Foundation

/// Pi·OMP의 공통 세션 형식. provider 매핑과 가격 계산은 수집 이후에 수행.
enum PiSessionParser {
    static func parse(_ data: Data, path: String, sourceID: String) throws -> [UsageRecord] {
        var sessionID: String?
        var parent: String?
        var records: [UsageRecord] = []
        for line in JSONLScanning.lines(in: data) {
            guard !Task.isCancelled else { throw CancellationError() }
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            let object: [String: Any]
            do {
                object = try UsageJSON.object(line)
            } catch {
                records.append(UsageRecord(
                    sourceID: sourceID, formatID: "pi-session", filePath: path,
                    sessionID: sessionID, parentSession: parent, kind: "invalid",
                    issues: [.invalidMetadata]
                ))
                continue
            }
            if object["type"] as? String == "session" {
                sessionID = UsageJSON.string(object["id"])
                parent = UsageJSON.string(object["parentSession"])
                continue
            }
            guard var record = record(object, sourceID: sourceID) else { continue }
            record.filePath = path
            record.sessionID = sessionID
            record.parentSession = parent
            records.append(record)
        }
        return records
    }

    static func record(_ object: [String: Any], sourceID: String) -> UsageRecord? {
        guard let type = object["type"] as? String else { return nil }
        let payload: [String: Any]
        switch type {
        case "message":
            guard let message = object["message"] as? [String: Any],
                  ["assistant", "toolResult"].contains(message["role"] as? String ?? "") else { return nil }
            payload = message
        case "usage", "model_usage", "compaction", "branch_summary":
            payload = object
        default:
            return nil
        }
        guard let usageValue = payload["usage"] else { return nil }
        let envelopeTime = UsageJSON.date(object["timestamp"])
        let timestamp: Date?
        if sourceID == "omp", type == "message" {
            let messageTime = (payload["timestamp"] as? NSNumber).flatMap { value -> Date? in
                guard let number = ProviderParse.number(value), number > 0 else { return nil }
                return UsageJSON.date(value, milliseconds: true)
            }
            timestamp = messageTime ?? envelopeTime
        } else {
            timestamp = envelopeTime ?? UsageJSON.date(payload["timestamp"], milliseconds: true)
        }
        var record = UsageRecord(
            sourceID: sourceID, formatID: "pi-session", id: UsageJSON.string(object["id"]),
            responseID: UsageJSON.string(payload["responseId"]), kind: type,
            timestamp: timestamp,
            providerID: UsageJSON.string(payload["provider"]), model: UsageJSON.string(payload["model"]),
            responseModel: UsageJSON.string(payload["responseModel"]) ?? UsageJSON.string(payload["upstreamModel"]),
            upstreamProvider: UsageJSON.string(payload["upstreamProvider"]),
            serviceTier: UsageJSON.string(payload["serviceTier"]), costOrigin: .estimated, zeroCostIsUnknown: true
        )
        if record.timestamp == nil || record.providerID == nil || record.effectiveModel == nil {
            record.issues.insert(.invalidMetadata)
        }
        guard let usage = usageValue as? [String: Any] else {
            record.issues.insert(.invalidMetadata)
            return record
        }
        if sourceID == "omp" {
            ompTokens(usage, into: &record)
        } else {
            UsageJSON.tokens(
                into: &record, input: usage["input"], output: usage["output"], cacheRead: usage["cacheRead"],
                cacheWrite: usage["cacheWrite"], cacheWrite1h: usage["cacheWrite1h"], total: usage["totalTokens"]
            )
        }
        if let reasoning = usage[sourceID == "omp" ? "reasoningTokens" : "reasoning"] {
            record.reasoningTokens = UsageLogNumbers.count(reasoning)
            if record.reasoningTokens == nil { record.issues.insert(.invalidNumbers) }
            if sourceID == "omp", let reasoning = record.reasoningTokens,
               let output = UsageLogNumbers.count(usage["output"], missing: 0), reasoning > output {
                record.issues.insert(.invalidNumbers)
            }
        }
        if let value = usage["cost"] {
            if let cost = value as? [String: Any] {
                UsageJSON.cost(cost["total"], into: &record)
                if sourceID == "pi", cost["totalFromProvider"] as? Bool == true {
                    record.costOrigin = .reported
                    record.zeroCostIsUnknown = false
                }
            } else {
                record.issues.insert(.invalidNumbers)
            }
        }
        return record
    }

    private static func ompTokens(_ usage: [String: Any], into record: inout UsageRecord) {
        UsageJSON.tokens(
            into: &record, input: usage["input"], output: usage["output"], cacheRead: usage["cacheRead"],
            cacheWrite: usage["cacheWrite"], total: usage["totalTokens"]
        )
        guard var tokens = record.tokens else { return }
        var completeBuckets = true
        if let value = usage["orchestration"] {
            if let orchestration = value as? [String: Any],
               let input = UsageLogNumbers.count(orchestration["input"], missing: 0),
               let output = UsageLogNumbers.count(orchestration["output"], missing: 0),
               let read = UsageLogNumbers.count(orchestration["cacheRead"], missing: 0),
               let billedInput = UsageLogNumbers.sum(tokens.input, input),
               let billedOutput = UsageLogNumbers.sum(tokens.output, output),
               let billedRead = UsageLogNumbers.sum(tokens.cacheRead, read),
               let sum = UsageLogNumbers.sum(billedInput, billedOutput, billedRead, tokens.cacheWrite5m) {
                tokens.input = billedInput
                tokens.output = billedOutput
                tokens.cacheRead = billedRead
                if usage["totalTokens"] == nil { record.totalTokens = sum }
            } else {
                completeBuckets = false
                record.issues.insert(usage["totalTokens"] == nil ? .invalidNumbers : .unsupportedPricing)
            }
        }
        if let value = usage["cttl"] {
            if let ttl = value as? [String: Any],
               let fiveMinute = UsageLogNumbers.count(ttl["ephemeral5m"], missing: 0),
               let oneHour = UsageLogNumbers.count(ttl["ephemeral1h"], missing: 0),
               let sum = UsageLogNumbers.sum(fiveMinute, oneHour), sum == tokens.cacheWrite5m {
                tokens.cacheWrite5m = fiveMinute
                tokens.cacheWrite1h = oneHour
            } else {
                completeBuckets = false
                let missingTotal = usage["cacheWrite"] == nil && usage["totalTokens"] == nil
                record.issues.insert(missingTotal ? .invalidNumbers : .unsupportedPricing)
            }
        }
        record.tokens = completeBuckets ? tokens : nil
    }
}
