import CryptoKit
import Foundation

enum HermesUsageParser {
    private static let tokenColumns = ["input_tokens", "output_tokens", "cache_read_tokens", "cache_write_tokens"]
    private static let routeColumns = ["model", "billing_provider", "billing_base_url", "billing_mode"]

    static func database(_ database: UsageDatabase, path: String) throws -> [UsageRecord] {
        let tables = try database.tables()
        guard tables.contains("sessions") else { throw CocoaError(.coderReadCorrupt) }
        let columns = try database.columns(in: "sessions")
        guard columns.contains("id") else { throw CocoaError(.coderReadCorrupt) }
        let needed = ["id", "model", "billing_provider", "started_at", "ended_at", "input_tokens", "output_tokens",
                      "cache_read_tokens", "cache_write_tokens", "reasoning_tokens", "estimated_cost_usd",
                      "actual_cost_usd", "cost_status", "cost_source", "billing_base_url", "billing_mode", "model_config"]
        let selection = needed.filter(columns.contains).map(UsageDatabase.identifier).joined(separator: ", ")
        var sessions: [(String, [String: Any])] = []
        try database.rows("SELECT \(selection) FROM sessions") { row in
            guard let session = UsageJSON.string(row["id"]) else { throw CocoaError(.coderReadCorrupt) }
            sessions.append((session, row))
        }
        var models: [String: [[String: Any]]] = [:]
        if tables.contains("session_model_usage") {
            try database.rows("SELECT * FROM session_model_usage") { row in
                guard let session = UsageJSON.string(row["session_id"]) else { throw CocoaError(.coderReadCorrupt) }
                models[session, default: []].append(row)
            }
        }
        var result: [UsageRecord] = []
        for (session, row) in sessions {
            let modelRows = models.removeValue(forKey: session) ?? []
            let binding = codexBinding(row["model_config"])
            for var model in modelRows {
                model["started_at"] = row["started_at"]
                result.append(try record(model, session: session, path: path, perModel: true, binding: binding))
            }
            let main = modelRows.filter(isMain)
            if let remainder = try residual(row, main: main, session: session, path: path, binding: binding) {
                result.append(remainder)
            }
        }
        guard models.isEmpty else { throw CocoaError(.coderReadCorrupt) }
        return result
    }

    private static func isMain(_ row: [String: Any]) -> Bool {
        let task = UsageJSON.string(row["task"])
        return task == nil || task == "voice_chat"
    }

    private static func codexBinding(_ value: Any?) -> (thread: String?, invalid: Bool) {
        guard let value else { return (nil, false) }
        guard let text = value as? String,
              let object = try? UsageJSON.object(Data(text.utf8)) else { return (nil, true) }
        if let thread = object["codex_thread_id"], !(thread is NSNull), !(thread is String) { return (nil, true) }
        return (UsageJSON.string(object["codex_thread_id"]), false)
    }

    private static func residual(
        _ row: [String: Any], main: [[String: Any]], session: String, path: String,
        binding: (thread: String?, invalid: Bool)
    ) throws -> UsageRecord? {
        var original = try record(row, session: session, path: path, perModel: false, binding: binding)
        guard !main.isEmpty else { return original }
        var remainder = row
        for column in tokenColumns {
            guard let total = UsageLogNumbers.count(row[column], missing: 0),
                  let covered = count(column, in: main), total >= covered else {
                original.issues.insert(.unresolvedMirror)
                return original
            }
            remainder[column] = total - covered
        }
        if let total = UsageLogNumbers.count(row["reasoning_tokens"]) {
            guard let covered = count("reasoning_tokens", in: main), total >= covered else {
                original.issues.insert(.unresolvedMirror)
                return original
            }
            remainder["reasoning_tokens"] = total - covered
        } else {
            remainder.removeValue(forKey: "reasoning_tokens")
        }
        // 보조 호출은 세션 합계 밖 기록. 본 호출의 비용 열끼리만 차감.
        var hasRemainingCost = false
        var costCoverageKnown = true
        for column in ["estimated_cost_usd", "actual_cost_usd"] {
            guard let total = amount(row[column]), let covered = amount(column, in: main), total + 1e-9 >= covered else {
                costCoverageKnown = false
                continue
            }
            let remaining = max(0, total - covered)
            remainder[column] = remaining
            hasRemainingCost = hasRemainingCost || remaining > 1e-9
        }
        let hasRemainingTokens = tokenColumns.contains { (remainder[$0] as? Int ?? 0) > 0 }
        guard hasRemainingTokens || hasRemainingCost else {
            let hasKnownCost = original.recordedCostUSD.map { $0 > 0 || !original.zeroCostIsUnknown } ?? false
            if (!costCoverageKnown && hasKnownCost) || original.issues.contains(.invalidNumbers) {
                original.issues.insert(.unresolvedMirror)
                return original
            }
            return nil
        }
        let status = UsageJSON.string(row["cost_status"])
        if !costCoverageKnown || main.contains(where: { UsageJSON.string($0["cost_status"]) != status }) {
            remainder.removeValue(forKey: "estimated_cost_usd")
            remainder.removeValue(forKey: "actual_cost_usd")
            remainder["cost_status"] = "unknown"
        }
        var result = try record(remainder, session: session, path: path, perModel: false, binding: binding)
        result.kind = "session-residual"
        result.issues.formUnion(original.issues)
        let hasRoute = UsageJSON.string(row["model"]) != nil && UsageJSON.string(row["billing_provider"]) != nil
        if !hasRoute || main.contains(where: { model in
            routeColumns.contains { UsageJSON.string(model[$0]) != UsageJSON.string(row[$0]) }
        }) {
            result.issues.insert(.invalidMetadata)
        }
        return result
    }

    private static func count(_ column: String, in rows: [[String: Any]]) -> Int? {
        var sum = 0
        for row in rows {
            guard let value = UsageLogNumbers.count(row[column], missing: 0),
                  let next = UsageLogNumbers.sum(sum, value) else { return nil }
            sum = next
        }
        return sum
    }

    private static func amount(_ value: Any?) -> Double? {
        guard let value else { return 0 }
        guard let number = ProviderParse.number(value), number >= 0 else { return nil }
        return number
    }

    private static func amount(_ column: String, in rows: [[String: Any]]) -> Double? {
        var sum = 0.0
        for row in rows {
            guard let value = amount(row[column]), (sum + value).isFinite else { return nil }
            sum += value
        }
        return sum
    }

    private static func record(
        _ row: [String: Any], session: String, path: String, perModel: Bool,
        binding: (thread: String?, invalid: Bool)
    ) throws -> UsageRecord {
        let components = ["model", "billing_provider", "billing_base_url", "billing_mode", "task"]
            .map { row[$0] as? String ?? "" }
        let key = try JSONSerialization.data(withJSONObject: components)
        var record = UsageRecord(
            sourceID: "hermes", formatID: "hermes-db", granularity: .aggregate, filePath: path,
            sessionID: session, id: SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined(),
            kind: perModel ? "model-total" : "session-total",
            timestamp: UsageJSON.date(row["first_seen"] ?? row["started_at"]),
            intervalEnd: UsageJSON.date(perModel ? row["last_seen"] : row["ended_at"]),
            providerID: UsageJSON.string(row["billing_provider"]), model: UsageJSON.string(row["model"])
        )
        if isMain(row), record.providerID == "openai-codex" {
            record.mirroredSessionID = binding.thread
            if binding.thread != nil { record.issues.insert(.unresolvedMirror) }
            if binding.invalid { record.issues.insert(.invalidMetadata) }
        }
        UsageJSON.tokens(
            into: &record, input: row["input_tokens"], output: row["output_tokens"],
            cacheRead: row["cache_read_tokens"], cacheWrite: row["cache_write_tokens"]
        )
        if let reasoning = row["reasoning_tokens"] {
            record.reasoningTokens = UsageLogNumbers.count(reasoning)
            if record.reasoningTokens == nil { record.issues.insert(.invalidNumbers) }
        }
        // 요청 시각이 없는 누적 원장은 하루 안에 끝난 구간만 일별 이력에 반영.
        let hasDailyInterval = record.timestamp.flatMap { start in
            record.intervalEnd.map { end in end >= start && Calendar.current.isDate(start, inSameDayAs: end) }
        } ?? false
        if !hasDailyInterval { record.issues.insert(.invalidMetadata) }
        cost(row, into: &record)
        return record
    }

    private static func cost(_ row: [String: Any], into record: inout UsageRecord) {
        record.costOrigin = .estimated
        record.zeroCostIsUnknown = true
        guard let actual = amount(row["actual_cost_usd"]), let estimated = amount(row["estimated_cost_usd"]) else {
            record.issues.insert(.invalidNumbers)
            return
        }
        let status = UsageJSON.string(row["cost_status"])
        let included = status == "included" || (status == nil && UsageJSON.string(row["billing_mode"]) == "subscription_included")
        // 두 열의 양수 누적액은 서로 겹치는 범위를 알 수 없어 전체 보고액으로 확정하지 않음.
        guard actual == 0 || estimated == 0 else { return }
        if included {
            guard actual == 0, estimated == 0 else { return }
            record.recordedCostUSD = 0
            record.costOrigin = .reported
            record.zeroCostIsUnknown = false
        } else if status == "actual" {
            guard row["actual_cost_usd"] != nil || row["estimated_cost_usd"] != nil else { return }
            record.recordedCostUSD = max(actual, estimated)
            record.costOrigin = .reported
            record.zeroCostIsUnknown = false
        } else if status == "estimated" || status == nil {
            if actual > 0 {
                guard status == nil else { return }
                record.recordedCostUSD = actual
                record.costOrigin = .reported
                record.zeroCostIsUnknown = false
            } else if row["estimated_cost_usd"] != nil {
                record.recordedCostUSD = estimated
            }
        }
    }
}
