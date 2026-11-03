import Foundation

enum DevinHistoryError: Error, LocalizedError, CategorizedError, UserPresentableError {
    case unreadable

    var errorDescription: String? {
        "Devin CLI usage history could not be read. Check the local session files and try again."
    }

    var errorCategory: ErrorCategory { .storage }
    var presentationMessage: LocalizedMessage { .init(errorDescription!) }
}

/// SQLite·파일 저장소의 요청별 사용량 집계. 현재 컨텍스트 크기와 계정 할당량은 제외.
actor DevinUsageScanner {
    struct Record: Sendable {
        var id: String
        var timestamp: Date
        var model: String?
        var tokens: TokenBreakdown
    }

    struct Parsed: Sendable {
        var records: [Record] = []
        var invalidRows = 0
    }

    struct Result: Sendable {
        var series: DailyUsageSeries
        var invalidRows: Int

        var warnings: [String] {
            var values: [String] = []
            if invalidRows > 0 {
                values.append("Some Devin CLI usage records are invalid. Totals may be incomplete.")
            }
            if series.daily.contains(where: { $0.costUSD == nil }) {
                values.append("Some Devin CLI usage has no known model price. Affected periods show tokens only.")
            }
            return values
        }

        func totalSpendLines(now: Date) -> [MetricLine] {
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: true)
            // 미가격 요청이 섞인 기간의 일부 비용을 전체 비용으로 표시하지 않음.
            if series.daily.contains(where: { $0.costUSD == nil }),
               let index = lines.firstIndex(where: { $0.label == TotalSpendPeriod.last30.lineLabel }),
               case .values(let label, let values, _, _, _, _) = lines[index] {
                lines[index] = .values(label: label, values: values.filter { $0.kind != .dollars })
            }
            return lines
        }
    }

    private let sqlite: any SQLiteAccessing
    private let environment: any EnvironmentReading
    private let homeDirectory: URL

    init(
        sqlite: any SQLiteAccessing = SQLiteCLIAccessor(),
        environment: any EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.sqlite = sqlite
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var directory: URL {
        func configured(_ key: String) -> URL? {
            guard let path = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !path.isEmpty else { return nil }
            if path == "~" { return homeDirectory }
            if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        let root = configured("DEVIN_SESSIONS_DIR")
            ?? (configured("XDG_DATA_HOME") ?? homeDirectory.appendingPathComponent(".local/share"))
                .appendingPathComponent("devin")
        return root.appendingPathComponent("cli", isDirectory: true)
    }

    func scan(now: Date, pricing: ModelPricing) throws -> Result? {
        try Task.checkCancellation()
        var parsed = Parsed()
        var foundStore = false
        let directory = directory
        let database = directory.appendingPathComponent("sessions.db")
        do {
            if try Self.exists(database) {
                foundStore = true
                guard let json = try sqlite.queryValue(path: database.path, sql: Self.dataSQL),
                      let data = json.data(using: .utf8),
                      let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]]
                else { throw DevinHistoryError.unreadable }
                for row in rows {
                    try Task.checkCancellation()
                    guard row.count == 5, let session = row[0] as? String,
                          let node = UsageLogNumbers.count(row[1])
                    else {
                        parsed.invalidRows += 1
                        continue
                    }
                    if row[4] is NSNull { continue }
                    guard let metadata = row[4] as? [String: Any] else {
                        parsed.invalidRows += 1
                        continue
                    }
                    if metadata["metrics"] == nil || metadata["metrics"] is NSNull { continue }
                    Self.append(metadata: metadata, messageID: row[3] as? String,
                                fallbackID: "\(session):\(node)", fallbackDate: row[2], to: &parsed)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            foundStore = true
            parsed.invalidRows += 1
            AppDiagnostics.record(.historyScan, result: .degraded, providerID: "devin", error: error,
                                  localContext: "SQLite history")
        }
        do {
            let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
            if try Self.exists(sessions) {
                foundStore = true
                var scanned: Set<String> = []
                for session in try FileManager.default.contentsOfDirectory(
                    at: sessions, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ) {
                    try Task.checkCancellation()
                    do {
                        guard try session.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                        let log = session.appendingPathComponent("log.jsonl").resolvingSymlinksInPath()
                        guard try Self.exists(log), scanned.insert(log.path).inserted else { continue }
                        guard let meta = ProviderParse.jsonObject(try Data(contentsOf: session.appendingPathComponent("meta.json"))),
                              UsageLogNumbers.count(meta["v"]) == 1, let id = meta["id"] as? String
                        else { throw DevinHistoryError.unreadable }
                        let file = try Self.parseLog(try Data(contentsOf: log), sessionID: id)
                        parsed.records += file.records
                        parsed.invalidRows += file.invalidRows
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        parsed.invalidRows += 1
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            foundStore = true
            parsed.invalidRows += 1
            AppDiagnostics.record(.historyScan, result: .degraded, providerID: "devin", error: error,
                                  localContext: "file history")
        }
        guard foundStore else { return nil }
        return Self.aggregate(parsed, now: now, pricing: pricing)
    }

    static func parseLog(_ data: Data, sessionID: String) throws -> Parsed {
        var parsed = Parsed()
        var nodes: [Int: (node: [String: Any], date: Any?)] = [:]
        let complete = data.last == 0x0A ? data : data.prefix(upTo: data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0)
        for line in JSONLScanning.lines(in: complete) {
            try Task.checkCancellation()
            guard let object = ProviderParse.jsonObject(line), let kind = object["kind"] as? String else {
                parsed.invalidRows += 1
                continue
            }
            guard kind == "node" else { continue }
            guard let node = object["node"] as? [String: Any], let id = UsageLogNumbers.count(node["id"]) else {
                parsed.invalidRows += 1
                continue
            }
            // 한 노드의 append 갱신은 마지막 상태만 사용. 분기에서 사라진 과거 요청도 실제 소비 이력.
            nodes[id] = (node, object["at"])
        }
        for (id, value) in nodes.sorted(by: { $0.key < $1.key }) {
            guard let message = value.node["message"] as? [String: Any] else {
                parsed.invalidRows += 1
                continue
            }
            guard message["role"] as? String == "assistant" else { continue }
            if message["metadata"] == nil || message["metadata"] is NSNull { continue }
            guard let metadata = message["metadata"] as? [String: Any] else {
                parsed.invalidRows += 1
                continue
            }
            if metadata["metrics"] == nil || metadata["metrics"] is NSNull { continue }
            append(metadata: metadata, messageID: message["message_id"] as? String,
                   fallbackID: "\(sessionID):\(id)", fallbackDate: value.date, to: &parsed)
        }
        return parsed
    }

    private static func append(
        metadata: [String: Any], messageID: String?, fallbackID: String, fallbackDate: Any?, to parsed: inout Parsed
    ) {
        let timestamp: Date?
        if let raw = metadata["created_at"] as? String {
            timestamp = OpenUsageISO8601.date(from: raw)
        } else {
            timestamp = UsageLogNumbers.count(fallbackDate).map { Date(timeIntervalSince1970: Double($0)) }
        }
        guard let timestamp, let metrics = metadata["metrics"] as? [String: Any],
              let input = UsageLogNumbers.count(metrics["input_tokens"]),
              let output = UsageLogNumbers.count(metrics["output_tokens"]),
              let read = UsageLogNumbers.count(metrics["cache_read_tokens"] is NSNull ? nil : metrics["cache_read_tokens"], missing: 0),
              let write = UsageLogNumbers.count(metrics["cache_creation_tokens"] is NSNull ? nil : metrics["cache_creation_tokens"], missing: 0),
              UsageLogNumbers.sum(input, output, read, write) != nil
        else {
            parsed.invalidRows += 1
            return
        }
        let requestID = (metadata["request_id"] as? String)?.nilIfEmpty
        let id = requestID.map { "request:\($0)" }
            ?? messageID?.nilIfEmpty.map { "message:\($0)" }
            ?? "node:\(fallbackID)"
        parsed.records.append(Record(
            id: id, timestamp: timestamp, model: (metadata["generation_model"] as? String)?.nilIfEmpty,
            tokens: TokenBreakdown(input: input, cacheWrite5m: write, cacheRead: read, output: output)
        ))
    }

    static func aggregate(
        _ parsed: Parsed, now: Date, pricing: ModelPricing, calendar: Calendar = .current
    ) -> Result {
        var requests: [String: Record] = [:]
        for record in parsed.records {
            // 복제·부분 저장이 겹치면 가장 완전한 요청 기록 하나만 반영.
            if let old = requests[record.id], old.tokens.totalTokens >= record.tokens.totalTokens { continue }
            requests[record.id] = record
        }
        let days = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        var totals: [String: (tokens: Int, cost: Double, unpriced: Bool)] = [:]
        var invalidRows = parsed.invalidRows
        var totalTokens = 0
        var totalCost = 0.0
        for record in requests.values.sorted(by: { $0.id < $1.id }) {
            let day = DailyUsageAccumulator.dayKey(from: record.timestamp, calendar: calendar)
            guard record.timestamp <= now, days.contains(day), record.tokens.totalTokens > 0 else { continue }
            let cost = record.model.flatMap { pricing.estimatedCostDollars(model: $0, tokens: record.tokens) }
            guard let nextTokens = UsageLogNumbers.sum(totalTokens, record.tokens.totalTokens),
                  cost.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  (totalCost + (cost ?? 0)).isFinite
            else {
                invalidRows += 1
                continue
            }
            totalTokens = nextTokens
            totalCost += cost ?? 0
            var value = totals[day] ?? (0, 0, false)
            value.tokens += record.tokens.totalTokens
            value.cost += cost ?? 0
            value.unpriced = value.unpriced || cost == nil
            totals[day] = value
        }
        return Result(series: DailyUsageSeries(daily: totals.map { day, value in
            DailyUsageEntry(date: day, totalTokens: value.tokens, costUSD: value.unpriced ? nil : value.cost)
        }.sorted { $0.date > $1.date }), invalidRows: invalidRows)
    }

    private static func exists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return false
        }
    }

    /// 대화 본문 대신 집계에 필요한 메타데이터만 조회. 읽기 전용 accessor 사용.
    static let dataSQL = """
        SELECT json_group_array(CASE WHEN json_valid(chat_message) THEN json_array(
            session_id, node_id, created_at,
            json_extract(chat_message, '$.message_id'), json_extract(chat_message, '$.metadata')
        ) ELSE json_array(NULL) END) FROM message_nodes
        WHERE CASE WHEN json_valid(chat_message)
            THEN json_extract(chat_message, '$.role') = 'assistant' ELSE 1 END;
        """
}
