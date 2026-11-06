import Foundation

enum KimiHistoryError: Error, LocalizedError, CategorizedError, UserPresentableError {
    case unreadable
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unreadable:
            "Kimi Code usage history could not be read. Check the local session files and try again."
        case .unsupportedFormat:
            "Kimi Code usage history uses an unsupported format. Check for an OpenUsage update."
        }
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .unreadable: .storage
        case .unsupportedFormat: .decoding
        }
    }

    var presentationMessage: LocalizedMessage { .init(errorDescription!) }
}

/// Kimi Code wire의 요청별 토큰과 모델·캐시 조건을 확인한 요청의 API 비용 상당액 집계.
actor KimiUsageScanner {
    struct PricingInput: Sendable {
        var model: String
        var protocolName: String?
        var thinkingEffort: String?
        var tokens: TokenBreakdown
    }

    struct Record: Sendable {
        var timestamp: Date
        var tokens: Int
        var pricingInput: PricingInput? = nil
        var wireEntryID: String? = nil
    }

    struct ParsedFile: Sendable {
        var records: [Record] = []
        var invalidRows = 0
    }

    struct Result: Sendable {
        var series: DailyUsageSeries
        var invalidRows: Int
        var fileErrors: [KimiHistoryError] = []

        var readWarnings: [String] {
            Array(Set(fileErrors.map(\.localizedDescription))).sorted()
        }

        var warnings: [String] {
            var messages = readWarnings
            if invalidRows > 0 {
                messages.append("Some Kimi Code usage records are invalid. Token totals may be incomplete.")
            }
            if hasUnpricedUsage {
                messages.append("Some Kimi Code usage has unknown model routing or cache pricing. Affected periods show tokens only.")
            }
            return messages
        }

        var hasUnpricedUsage: Bool {
            series.daily.contains { $0.totalTokens > 0 && $0.costUSD == nil }
        }

        func totalSpendLines(now: Date) -> [MetricLine] {
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: true)
            return lines
        }
    }

    private struct Stamp: Equatable {
        var size: Int
        var modified: Date
    }

    private struct WireIdentity: Hashable {
        var id: String
        var timestamp: Date
        var tokens: Int
    }

    private let environment: EnvironmentReading
    private let homeDirectory: URL
    private var supplementalCollectors: [UsageFileCollector]?
    private var cache: [String: (stamp: Stamp, parsed: ParsedFile)] = [:]

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    func scan(now: Date, pricing: ModelPricing = .empty) async throws -> Result? {
        do {
            if supplementalCollectors == nil {
                supplementalCollectors = [UsageSourceCollectors.kimiWork(home: homeDirectory)]
            }
            var fileErrors: [KimiHistoryError] = []
            let paths = wireFiles(failures: &fileErrors)
            var work = UsageCollection(records: [])
            for collector in supplementalCollectors ?? [] {
                guard let collected = await collector.collect(since: .distantPast), !Task.isCancelled else { throw CancellationError() }
                work.records += collected.records
                work.sources += collected.sources
            }
            guard !paths.isEmpty || !fileErrors.isEmpty || work.sources.contains(where: { $0.status != .absent }) else {
                cache.removeAll()
                return nil
            }
            cache = cache.filter { paths.contains($0.key) }
            var files: [ParsedFile] = []
            var nativeEntries: [String: Set<WireIdentity>] = [:]
            for path in paths {
                try Task.checkCancellation()
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: path)
                    let stamp = Stamp(
                        size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                        modified: attributes[.modificationDate] as? Date ?? .distantPast
                    )
                    let parsed: ParsedFile
                    if let cached = cache[path], cached.stamp == stamp {
                        parsed = cached.parsed
                    } else {
                        parsed = try Self.parse(Data(contentsOf: URL(fileURLWithPath: path)))
                        cache[path] = (stamp, parsed)
                    }
                    files.append(parsed)
                    nativeEntries[path] = Set(parsed.records.compactMap { record in
                        record.wireEntryID.map { WireIdentity(id: $0, timestamp: record.timestamp, tokens: record.tokens) }
                    })
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    cache.removeValue(forKey: path)
                    fileErrors.append(error as? KimiHistoryError ?? .unreadable)
                }
            }
            if work.readFailureCount > 0 { fileErrors.append(.unreadable) }
            var supplemental = ParsedFile()
            for record in UsageRecordDeduplicator.records(work.records) {
                guard record.providerID == "kimi" else { continue }
                if let path = record.filePath, let id = record.id, let date = record.timestamp,
                   nativeEntries[path]?.contains(WireIdentity(id: id, timestamp: date, tokens: record.totalTokens)) == true {
                    continue
                }
                guard record.issues.isEmpty, let date = record.timestamp, record.tokens != nil else {
                    supplemental.invalidRows += 1
                    continue
                }
                supplemental.records.append(Record(timestamp: date, tokens: record.totalTokens))
            }
            files.append(supplemental)
            if files.allSatisfy({ $0.records.isEmpty }), let error = fileErrors.first { throw error }
            var result = Self.aggregate(files, now: now, pricing: pricing)
            result.fileErrors = fileErrors
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as KimiHistoryError {
            throw error
        } catch {
            throw KimiHistoryError.unreadable
        }
    }

    /// 알려진 session/agent 경로만 탐색. 백업·내보내기·구형 Python 로그는 집계하지 않음.
    private func wireFiles(failures: inout [KimiHistoryError]) -> [String] {
        let raw = environment.value(for: "KIMI_CODE_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = raw.flatMap { $0.isEmpty ? nil : $0 }.map { path in
            if path == "~" { return homeDirectory }
            if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: path, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".kimi-code", isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        let manager = FileManager.default
        func directories(_ root: URL) -> [URL] {
            do {
                return try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
                    .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                return []
            } catch {
                failures.append(.unreadable)
                return []
            }
        }
        var paths: Set<String> = []
        for workspace in directories(directory) {
            for session in directories(workspace) {
                let agents = directories(session.appendingPathComponent("agents", isDirectory: true))
                for agent in agents {
                    let wire = agent.appendingPathComponent("wire.jsonl")
                    do {
                        guard try wire.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                        paths.insert(wire.resolvingSymlinksInPath().path)
                    } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                        continue
                    } catch {
                        failures.append(.unreadable)
                    }
                }
            }
        }
        return paths.sorted()
    }

    static func parse(_ data: Data) throws -> ParsedFile {
        var result = ParsedFile()
        typealias Request = (alias: String, model: String, protocolName: String?, thinkingEffort: String?)
        var requests: [String: [String: Request]] = [:]
        // 마지막 JSON이 완전하면 줄바꿈 없이도 처리. append 중인 불완전 행만 다음 스캔으로 보류.
        let tailStart = data.lastIndex(of: 0x0A).map { data.index(after: $0) } ?? data.startIndex
        let tail = data.suffix(from: tailStart)
        let completeTail = tail.isEmpty || (try? JSONSerialization.jsonObject(with: tail, options: .fragmentsAllowed)) != nil
        let complete = completeTail ? data : data.prefix(upTo: tailStart)
        for (index, line) in JSONLScanning.lines(in: complete).enumerated() {
            try Task.checkCancellation()
            guard let object = ProviderParse.jsonObject(line), let type = object["type"] as? String else {
                requests.removeAll()
                result.invalidRows += 1
                continue
            }
            if type == "metadata" {
                guard let version = object["protocol_version"] as? String,
                      ["1.0", "1.1", "1.2", "1.3", "1.4", "1.5"].contains(version)
                else { throw KimiHistoryError.unsupportedFormat }
                continue
            }
            if type == "forked" {
                // fork는 원본 wire 전체를 복사. 복사된 요청은 원본에서만 집계.
                result = ParsedFile()
                requests.removeAll()
                continue
            }
            if type == "llm.request" {
                guard let agent = object["agentId"] as? String else {
                    requests.removeAll()
                    result.invalidRows += 1
                    continue
                }
                let scope: String? = switch object["kind"] as? String {
                case "loop": "turn"
                case "compaction": "session"
                default: nil
                }
                if let scope {
                    requests[agent]?.removeValue(forKey: scope)
                } else {
                    requests.removeValue(forKey: agent)
                }
                requests[agent]?.removeValue(forKey: "latest")
                if let alias = object["modelAlias"] as? String,
                   let model = object["model"] as? String,
                   !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let request = (alias, model, object["provider"] as? String, object["thinkingEffort"] as? String)
                    requests[agent, default: [:]]["latest"] = request
                    if let scope { requests[agent, default: [:]][scope] = request }
                }
                continue
            }
            guard type == "usage.record" else { continue }
            guard let alias = object["model"] as? String else {
                result.invalidRows += 1
                continue
            }
            guard alias.hasPrefix("kimi-code/") else { continue }
            guard let agent = object["agentId"] as? String else {
                result.invalidRows += 1
                continue
            }
            // 일반 turn과 background compaction은 같은 agent에서 겹칠 수 있어 scope별 요청 연결.
            let scopedRequest = (object["usageScope"] as? String).flatMap { scope in
                ["turn", "session"].contains(scope) ? requests[agent]?[scope] : nil
            }
            guard let request = scopedRequest ?? requests[agent]?["latest"], request.alias == alias,
                  let milliseconds = count(object["time"]),
                  let usage = object["usage"] as? [String: Any],
                  let input = count(usage["inputOther"]),
                  let output = count(usage["output"]),
                  let cacheWrite = count(usage["inputCacheCreation"])
            else {
                result.invalidRows += 1
                continue
            }
            // OpenAI 계열의 캐시 읽기 생략 시 inputOther는 전체 입력. 캐시 과금 구분은 미확정.
            let cacheReadUnknown = usage["inputCacheRead"] == nil
                && (scopedRequest?.protocolName == "openai" || scopedRequest?.protocolName == "openai_responses")
            guard let cacheRead = cacheReadUnknown ? 0 : count(usage["inputCacheRead"]),
                  let tokens = UsageLogNumbers.sum(input, output, cacheRead, cacheWrite)
            else {
                result.invalidRows += 1
                continue
            }
            // namespace는 사용자가 재설정 가능하므로 요청 API 모델명도 함께 제한.
            let model = request.model.lowercased()
            guard canonicalModel(model) != nil || model.hasPrefix("kimi-") else { continue }
            result.records.append(Record(
                timestamp: Date(timeIntervalSince1970: Double(milliseconds) / 1_000),
                tokens: tokens,
                pricingInput: cacheReadUnknown ? nil : scopedRequest.map { PricingInput(
                    model: $0.model, protocolName: $0.protocolName, thinkingEffort: $0.thinkingEffort,
                    tokens: TokenBreakdown(input: input, cacheWrite5m: cacheWrite, cacheRead: cacheRead, output: output)
                ) },
                wireEntryID: UsageJSON.string(object["id"]) ?? "row:\(index)"
            ))
        }
        return result
    }

    private static func count(_ value: Any?) -> Int? {
        guard value is NSNumber else { return nil }
        return UsageLogNumbers.count(value)
    }

    private static func canonicalModel(_ model: String) -> String? {
        switch model {
        case "k3", "k3-256k": "kimi-k3"
        case "k3.1-pro": "kimi-k3.1-pro"
        case "k3.1-pro-highspeed": "kimi-k3.1-pro-highspeed"
        default: nil
        }
    }

    private static func estimatedCost(_ input: PricingInput?, pricing: ModelPricing) -> Double? {
        guard let input, let canonical = canonicalModel(input.model),
              let effort = input.thinkingEffort, ["on", "low", "high", "max"].contains(effort),
              input.tokens.cacheWrite5m == 0
        else { return nil }
        switch input.protocolName {
        case "anthropic": break
        case "openai", "openai_responses":
            // 이 두 decoder의 input에는 TTL 미상의 캐시 쓰기가 포함될 수 있음.
            guard input.tokens.input == 0 else { return nil }
        default: return nil
        }
        guard let rates = pricing.resolve(model: canonical),
              input.tokens.cacheRead == 0 || rates.cacheReadIsExplicit
        else { return nil }
        return rates.costDollars(for: input.tokens)
    }

    static func aggregate(
        _ files: [ParsedFile], now: Date, calendar: Calendar = .current, pricing: ModelPricing = .empty
    ) -> Result {
        let days = UsageHistoryWindow.dayKeys(through: now, calendar: calendar)
        var totals: [String: Int] = [:]
        var costs: [String: Double] = [:]
        var unpricedDays: Set<String> = []
        var total = 0
        var invalidRows = files.reduce(0) { $0 + $1.invalidRows }
        for file in files {
            for record in file.records where record.timestamp <= now {
                let day = DailyUsageAccumulator.dayKey(from: record.timestamp, calendar: calendar)
                guard days.contains(day), record.tokens > 0 else { continue }
                let next = total.addingReportingOverflow(record.tokens)
                guard !next.overflow else {
                    invalidRows += 1
                    continue
                }
                total = next.partialValue
                totals[day, default: 0] += record.tokens
                if let cost = estimatedCost(record.pricingInput, pricing: pricing),
                   cost >= 0, cost.isFinite, ((costs[day] ?? 0) + cost).isFinite {
                    costs[day, default: 0] += cost
                } else {
                    unpricedDays.insert(day)
                }
            }
        }
        return Result(
            series: DailyUsageSeries(daily: totals.keys.sorted(by: >).map {
                DailyUsageEntry(date: $0, totalTokens: totals[$0]!, costUSD: unpricedDays.contains($0) ? nil : costs[$0])
            }),
            invalidRows: invalidRows
        )
    }
}
