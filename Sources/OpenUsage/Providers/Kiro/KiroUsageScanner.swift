import Foundation

enum KiroHistoryError: Error, LocalizedError, CategorizedError, UserPresentableError {
    case unreadable

    var errorDescription: String? {
        "Kiro CLI usage history could not be read. Check the local session files and try again."
    }

    var errorCategory: ErrorCategory { .storage }
    var presentationMessage: LocalizedMessage { .init(errorDescription!) }
}

/// V3 턴별 크레딧과 저장된 대화 길이를 기존 상단 통계로 환산.
actor KiroUsageScanner {
    struct Record: Sendable {
        var id: String
        var timestamp: Date
        var costUSD: Double
        var tokens: Int?
    }

    struct Parsed: Sendable {
        var records: [Record] = []
        var invalidRows = 0
    }

    struct Day: Sendable {
        var date: String
        var costUSD = 0.0
        var tokens = 0
        var missingTokens = false
    }

    struct Result: Sendable {
        var daily: [Day]
        var invalidRows: Int

        var warnings: [String] {
            var values: [String] = []
            if invalidRows > 0 {
                values.append("Some Kiro CLI usage records are invalid. Totals may be incomplete.")
            }
            if daily.contains(where: \.missingTokens) {
                values.append("Some Kiro CLI turns have no saved response history. Affected periods show cost only.")
            }
            return values
        }

        func totalSpendLines(now: Date) -> [MetricLine] {
            let today = DailyUsageAccumulator.dayKey(from: now)
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)
                .map { DailyUsageAccumulator.dayKey(from: $0) }
            let periods: [(String, [Day])] = [
                ("Today", daily.filter { $0.date == today }),
                ("Yesterday", daily.filter { $0.date == yesterday }),
                ("Last 30 Days", daily)
            ]
            return periods.compactMap { label, days in
                let cost = days.reduce(0) { $0 + $1.costUSD }
                let tokens = days.reduce(0) { $0 + $1.tokens }
                guard cost > 0 || tokens > 0 else { return nil }
                var values = [MetricValue(number: cost, kind: .dollars, estimated: true)]
                if !days.contains(where: \.missingTokens) {
                    values.append(MetricValue(number: Double(tokens), kind: .count, label: "tokens", estimated: true))
                }
                return .values(label: label, values: values)
            }
        }
    }

    let directory: URL

    init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = homeDirectory.appendingPathComponent(".kiro/sessions", isDirectory: true)
    }

    func scan(now: Date) throws -> Result? {
        do {
            try Task.checkCancellation()
            guard try Self.exists(directory) else { return nil }
            var parsed = Parsed()
            var scanned: Set<String> = []
            for workspace in try Self.folders(in: directory) {
                for session in try Self.folders(in: workspace) {
                    try Task.checkCancellation()
                    let log = session.appendingPathComponent("messages.jsonl").resolvingSymlinksInPath()
                    guard try Self.exists(log), scanned.insert(log.path).inserted else { continue }
                    let file = try Self.parse(try Data(contentsOf: log))
                    parsed.records += file.records
                    parsed.invalidRows += file.invalidRows
                }
            }
            return Self.aggregate(parsed, now: now)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KiroHistoryError.unreadable
        }
    }

    private struct Turn {
        var input = 0
        var output = 0
        var requests = 0
    }

    static func parse(_ data: Data) throws -> Parsed {
        var parsed = Parsed()
        var messages: [(id: String, payload: [String: Any], date: Date)] = []
        var positions: [String: Int] = [:]
        let complete = data.last == 0x0A ? data : data.prefix(upTo: data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0)
        for line in JSONLScanning.lines(in: complete) {
            try Task.checkCancellation()
            guard let object = ProviderParse.jsonObject(line), let id = (object["id"] as? String)?.nilIfEmpty,
                  let payload = object["payload"] as? [String: Any], payload["type"] is String,
                  let rawDate = object["timestamp"] as? String, let date = OpenUsageISO8601.date(from: rawDate)
            else {
                parsed.invalidRows += 1
                continue
            }
            let message = (id, payload, date)
            // 스트리밍·도구 상태 갱신은 처음 위치에서 마지막 내용으로 해석.
            if let index = positions[id] {
                messages[index] = message
            } else {
                positions[id] = messages.count
                messages.append(message)
            }
        }

        var context: [(id: String, chars: Int)] = []
        var contextChars = 0
        var turns: [String: Turn] = [:]
        var execution: String?
        var responseExecution: String?
        var needsResponse = true
        func beginResponse(_ id: String?) {
            guard let id else { return }
            if needsResponse || responseExecution != id {
                turns[id, default: Turn()].input += estimate(contextChars)
                turns[id, default: Turn()].requests += 1
                needsResponse = false
                responseExecution = id
            }
        }

        for message in messages {
            try Task.checkCancellation()
            let payload = message.payload
            let type = payload["type"] as! String
            let turnID = (payload["executionId"] as? String)?.nilIfEmpty ?? execution
            var chars = 0
            switch type {
            case "turn_start":
                execution = (payload["executionId"] as? String)?.nilIfEmpty
                needsResponse = true
            case "session_metadata":
                guard payload["key"] as? String == "modelFallback" else { break }
                guard let value = payload["value"] as? [String: Any] else {
                    parsed.invalidRows += 1
                    continue
                }
                let abandoned = Set((value["abandonedMessageIds"] as? [Any] ?? []).compactMap { $0 as? String })
                if !abandoned.isEmpty {
                    context.removeAll { abandoned.contains($0.id) }
                    contextChars = context.reduce(0) { $0 + $1.chars }
                }
                // 적용된 모델 전환만 같은 턴의 새 요청 시작. 거절 안내에는 전환 대상 없음.
                if value["to"] is String { needsResponse = true }
            case "tombstone":
                guard let kind = payload["kind"] as? String, ["checkpoint_revert", "summarization"].contains(kind) else {
                    parsed.invalidRows += 1
                    continue
                }
                if let target = payload["effectiveFromMessageId"] as? String,
                   let index = context.firstIndex(where: { $0.id == target }) {
                    contextChars -= context[index...].reduce(0) { $0 + $1.chars }
                    context.removeSubrange(index...)
                }
                // 이후 입력 컨텍스트만 되감기. 이미 소비한 턴 기록은 보존.
                needsResponse = true
            case "session_start", "system", "user", "tool_result", "assistant":
                guard let content = payload["content"] as? String else {
                    parsed.invalidRows += 1
                    continue
                }
                chars = content.utf16.count
                if type == "assistant" {
                    let operation = payload["operationType"] as? String ?? "Say"
                    guard ["Say", "Reasoning", "Print", "Summary"].contains(operation) else {
                        parsed.invalidRows += 1
                        continue
                    }
                    if operation == "Print" { continue }
                    if operation == "Summary" {
                        needsResponse = true
                    } else {
                        beginResponse(turnID)
                        if operation == "Say", let turnID {
                            turns[turnID, default: Turn()].output += estimate(chars)
                        }
                    }
                } else {
                    needsResponse = true
                }
            case "tool_call":
                guard let args = payload["args"] as? [String: Any] else {
                    parsed.invalidRows += 1
                    continue
                }
                beginResponse(turnID)
                chars = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]),
                               as: UTF8.self).utf16.count
            case "sub_agent_start":
                beginResponse((payload["parentExecutionId"] as? String)?.nilIfEmpty ?? execution)
                chars = (payload["prompt"] as? String)?.utf16.count ?? 0
            case "sub_agent_complete":
                chars = (payload["response"] as? String)?.utf16.count ?? 0
                needsResponse = true
            case "usage_summary":
                guard let credits = credits(in: payload), (credits * dollarsPerCredit).isFinite else {
                    parsed.invalidRows += 1
                    continue
                }
                let turn = turnID.flatMap { turns[$0] }
                let tokens = turn.flatMap { $0.requests > 0 ? UsageLogNumbers.sum($0.input, $0.output) : nil }
                if credits > 0 || (tokens ?? 0) > 0 {
                    parsed.records.append(Record(id: turnID ?? message.id, timestamp: message.date,
                                                 costUSD: credits * dollarsPerCredit, tokens: tokens))
                }
            default:
                break
            }
            context.append((message.id, chars))
            contextChars += chars
        }
        return parsed
    }

    static func aggregate(_ parsed: Parsed, now: Date, calendar: Calendar = .current) -> Result {
        var records: [String: Record] = [:]
        for record in parsed.records where record.timestamp <= now {
            if let old = records[record.id] {
                // 복사된 실행이나 부분 저장이 겹치면 가장 완전한 값 하나만 사용.
                records[record.id] = Record(id: record.id, timestamp: max(old.timestamp, record.timestamp),
                                           costUSD: max(old.costUSD, record.costUSD),
                                           tokens: [old.tokens, record.tokens].compactMap { $0 }.max())
            } else {
                records[record.id] = record
            }
        }
        let days = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        var daily: [String: Day] = [:]
        var invalidRows = parsed.invalidRows
        var totalTokens = 0
        var totalCost = 0.0
        for record in records.values.sorted(by: { $0.id < $1.id }) {
            let day = DailyUsageAccumulator.dayKey(from: record.timestamp, calendar: calendar)
            guard record.timestamp <= now, days.contains(day) else { continue }
            guard let nextTokens = UsageLogNumbers.sum(totalTokens, record.tokens ?? 0),
                  record.costUSD.isFinite, record.costUSD >= 0, (totalCost + record.costUSD).isFinite else {
                invalidRows += 1
                continue
            }
            totalTokens = nextTokens
            totalCost += record.costUSD
            var value = daily[day] ?? Day(date: day)
            value.costUSD += record.costUSD
            value.tokens += record.tokens ?? 0
            value.missingTokens = value.missingTokens || (record.tokens == nil && record.costUSD > 0)
            daily[day] = value
        }
        return Result(daily: daily.values.sorted { $0.date > $1.date }, invalidRows: invalidRows)
    }

    private static let dollarsPerCredit = 0.04

    private static func estimate(_ chars: Int) -> Int {
        chars / 4 + (chars % 4 == 0 ? 0 : 1)
    }

    private static func credits(in payload: [String: Any]) -> Double? {
        guard let entries = payload["promptTurnSummaries"] as? [[String: Any]] else { return nil }
        var total = 0.0
        for entry in entries {
            let unit = ((entry["unit"] ?? entry["unitPlural"]) as? String)?.lowercased()
            guard unit == "credit" || unit == "credits", let usage = entry["usage"] as? NSNumber,
                  CFGetTypeID(usage) != CFBooleanGetTypeID(), usage.doubleValue.isFinite, usage.doubleValue >= 0,
                  (total + usage.doubleValue).isFinite else { return nil }
            total += usage.doubleValue
        }
        return total
    }

    private static func folders(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])
            .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .sorted { $0.path < $1.path }
    }

    private static func exists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }
}
