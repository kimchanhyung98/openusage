import Foundation

/// 완료 턴 스냅샷의 보고 사용량. 계보를 확인한 독립 세션만 로그보다 우선.
struct GrokSessionUsageScanner: Sendable {
    var files: TextFileAccessing

    struct Result: Sendable {
        var collection: UsageCollection
        var preferredSessionIDs: Set<String>
        var incompleteRows: Int
    }

    func collect(root: URL) -> Result? {
        guard !Task.isCancelled else { return nil }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let discovery = UsageFileDiscovery.files(under: [root]) { url in
            ["usage.json", "summary.json"].contains(url.lastPathComponent)
                && url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .standardizedFileURL == root.standardizedFileURL
        }
        var summaries: [String: [String: Any]] = [:]
        var parents: Set<String> = []
        var failed = discovery.failures
        for file in discovery.files where file.path.hasSuffix("/summary.json") {
            guard !Task.isCancelled else { return nil }
            do {
                let summary = try UsageJSON.object(Data(files.readText(file.path).utf8))
                summaries[URL(fileURLWithPath: file.path).deletingLastPathComponent().path] = summary
                if let parent = UsageJSON.string(summary["parent_session_id"]) { parents.insert(parent) }
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                failed += 1
            }
        }
        var parsedFiles: [Parsed] = []
        var completed = 0
        for file in discovery.files where file.path.hasSuffix("/usage.json") {
            guard !Task.isCancelled else { return nil }
            let directory = URL(fileURLWithPath: file.path).deletingLastPathComponent()
            let parsed: Parsed
            do {
                parsed = Self.parse(try files.readText(file.path), path: file.path)
                completed += 1
            } catch is CancellationError {
                return nil
            } catch {
                guard !Task.isCancelled else { return nil }
                failed += 1
                continue
            }
            var candidate = parsed
            let summary = summaries[directory.path]
            let info = summary?["info"] as? [String: Any]
            let id = UsageJSON.string(info?["id"])
            let kind = UsageJSON.string(summary?["session_kind"])
            let standalone = id == parsed.sessionID && id == directory.lastPathComponent
                && Self.absent(summary?["parent_session_id"]) && Self.absent(summary?["forked_at"])
                && (kind == nil || kind == "worktree")
                && !parents.contains(parsed.sessionID)
                && !files.exists(directory.appendingPathComponent("subagents").path)
            candidate.usable = candidate.usable && standalone
            candidate.parentID = UsageJSON.string(summary?["parent_session_id"])
            parsedFiles.append(candidate)
        }
        let duplicates = Set(Dictionary(grouping: parsedFiles, by: \.sessionID).filter { $0.value.count > 1 }.keys)
        var records: [UsageRecord] = []
        var preferred: Set<String> = []
        var incomplete = 0
        for parsed in parsedFiles {
            let usable = parsed.usable && !duplicates.contains(parsed.sessionID)
            if usable, !parsed.records.isEmpty { preferred.insert(parsed.sessionID) }
            incomplete += usable ? parsed.incompleteRows : 0
            records += parsed.records.map { record in
                var record = record
                record.parentSession = parsed.parentID
                if !usable { record.issues.insert(.unresolvedMirror) }
                return record
            }
        }
        guard !Task.isCancelled else { return nil }
        UsageRecordDiagnostics.report(records)
        if failed > 0 || incomplete > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: failed > 0 ? .storage : .decoding, providerID: "grok",
                localContext: "source=grok-session; unreadable_stores=\(failed); incomplete_turns=\(incomplete)"
            )
        }
        return Result(
            collection: UsageCollection(records: records, sources: [UsageSourceState(
                sourceID: "grok-session", providerID: "grok", completedStores: completed, failedStores: failed
            )]),
            preferredSessionIDs: preferred, incompleteRows: incomplete
        )
    }

    struct Parsed {
        var sessionID: String
        var parentID: String? = nil
        var records: [UsageRecord]
        var usable: Bool
        var incompleteRows: Int
    }

    static func parse(_ text: String, path: String) -> Parsed {
        let fallbackID = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        var id = fallbackID
        do {
            let object = try UsageJSON.object(Data(text.utf8))
            guard let session = UsageJSON.string(object["sessionId"]), session == fallbackID,
                  let turns = object["turns"] as? [[String: Any]],
                  let sessionUsage = object["session"] as? [String: Any] else { throw ParseError.metadata }
            id = session
            var seen: Set<Int> = []
            var records: [UsageRecord] = []
            var turnTotals: [Totals] = []
            var incomplete = 0
            for turn in turns {
                guard let number = UsageLogNumbers.count(turn["turnNumber"]), number <= Int(UInt32.max),
                      seen.insert(number).inserted,
                      let timestamp = UsageJSON.string(turn["endedAt"]).flatMap(OpenUsageISO8601.date(from:))
                else { throw ParseError.metadata }
                let models = turn["modelUsage"] as? [String: [String: Any]] ?? [:]
                guard turn["modelUsage"] == nil || turn["modelUsage"] is [String: [String: Any]] else {
                    throw ParseError.metadata
                }
                let totals = try Totals(turn)
                var modelTotals: [Totals] = []
                for (model, row) in models.sorted(by: { $0.key < $1.key }) {
                    guard UsageJSON.string(model) != nil else { throw ParseError.metadata }
                    let values = try Totals(row)
                    modelTotals.append(values)
                    var record = UsageRecord(
                        sourceID: "grok-session", formatID: "grok.session-usage.v1", granularity: .aggregate,
                        filePath: path, sessionID: id, id: "\(id):\(number):\(model)", kind: "completed-turn",
                        timestamp: timestamp, intervalEnd: timestamp, providerID: "grok", model: model,
                        tokens: TokenBreakdown(
                            input: values.input - values.cacheRead - values.cacheWrite,
                            cacheWrite5m: values.cacheWrite, cacheRead: values.cacheRead, output: values.output
                        ),
                        totalTokens: values.total, reasoningTokens: values.reasoning,
                        recordedCostUSD: values.cost, costOrigin: .reported, zeroCostIsUnknown: true
                    )
                    if totals.partial || totals.incomplete { record.recordedCostUSD = nil }
                    records.append(record)
                }
                guard try Totals.sum(modelTotals).matches(totals) else { throw ParseError.metadata }
                turnTotals.append(totals)
                if totals.incomplete || modelTotals.contains(where: \.incomplete) { incomplete += 1 }
            }
            guard try Totals.sum(turnTotals).matches(Totals(sessionUsage)) else { throw ParseError.metadata }
            return Parsed(sessionID: id, records: records, usable: true, incompleteRows: incomplete)
        } catch {
            let issue: UsageRecord.Issue = (error as? ParseError) == .numbers ? .invalidNumbers : .invalidMetadata
            let record = UsageRecord(
                sourceID: "grok-session", formatID: "grok.session-usage.v1", granularity: .aggregate,
                filePath: path, sessionID: id, kind: "invalid-session", providerID: "grok", issues: [issue]
            )
            return Parsed(sessionID: id, records: [record], usable: false, incompleteRows: 0)
        }
    }

    private enum ParseError: Error, Equatable { case numbers, metadata }

    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private struct Totals {
        let input: Int
        let output: Int
        let cacheRead: Int
        let cacheWrite: Int
        let reasoning: Int
        let total: Int
        let calls: Int
        let ticks: Int?
        let partial: Bool
        let incomplete: Bool

        var counts: [Int] { [input, output, cacheRead, cacheWrite, reasoning, total, calls] }
        var cost: Double? { !partial && !incomplete ? ticks.map { Double($0) / 10_000_000_000 } : nil }

        init(_ object: [String: Any]) throws {
            guard let input = UsageLogNumbers.count(object["inputTokens"], missing: 0),
                  let output = UsageLogNumbers.count(object["outputTokens"], missing: 0),
                  let read = UsageLogNumbers.count(object["cachedReadTokens"], missing: 0),
                  let write = UsageLogNumbers.count(object["cacheCreationTokens"], missing: 0),
                  let reasoning = UsageLogNumbers.count(object["reasoningTokens"], missing: 0),
                  let total = UsageLogNumbers.count(object["totalTokens"], missing: 0),
                  let calls = UsageLogNumbers.count(object["modelCalls"], missing: 0),
                  let expected = UsageLogNumbers.sum(input, output), total == expected,
                  let cache = UsageLogNumbers.sum(read, write), cache <= input else { throw ParseError.numbers }
            self.input = input
            self.output = output
            cacheRead = read
            cacheWrite = write
            self.reasoning = reasoning
            self.total = total
            self.calls = calls
            if let raw = object["costUsdTicks"], !(raw is NSNull) {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let value = Int(number.stringValue) else { throw ParseError.numbers }
                ticks = value > 0 ? value : nil
            } else {
                ticks = nil
            }
            partial = try Self.flag(object["costIsPartial"])
            incomplete = try Self.flag(object["usageIsIncomplete"])
        }

        private init(counts: [Int], ticks: Int?) {
            input = counts[0]
            output = counts[1]
            cacheRead = counts[2]
            cacheWrite = counts[3]
            reasoning = counts[4]
            total = counts[5]
            calls = counts[6]
            self.ticks = ticks
            partial = false
            incomplete = false
        }

        func matches(_ other: Totals) -> Bool { counts == other.counts && ticks == other.ticks }

        static func sum(_ values: [Totals]) throws -> Totals {
            var counts = [Int](repeating: 0, count: 7)
            var ticks = 0
            for value in values {
                for (index, amount) in value.counts.enumerated() {
                    guard let sum = UsageLogNumbers.sum(counts[index], amount) else { throw ParseError.numbers }
                    counts[index] = sum
                }
                guard let sum = UsageLogNumbers.sum(ticks, value.ticks ?? 0) else { throw ParseError.numbers }
                ticks = sum
            }
            return Totals(counts: counts, ticks: ticks > 0 ? ticks : nil)
        }

        private static func flag(_ value: Any?) throws -> Bool {
            guard let value else { return false }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ParseError.metadata
            }
            return number.boolValue
        }
    }
}
