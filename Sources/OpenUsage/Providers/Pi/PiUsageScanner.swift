import Foundation

/// pi session 로그에서 OpenUsage 카드 하나의 일별 token/cost series 구축 — pi 안에서 발생한 usage(pi로 구동한 Claude sub 등)를 해당 카드의 Usage Trend·spend 타일에 native source와 함께 합산.
/// cost 규칙은 Claude·Codex 로그 scanner와 동일한 `carried cost, else price` — pi의 per-message `usage.cost.total`이 있으면 그대로, `$0`(미산정 구독 usage)이면 공유 엔진으로 가격 산정. usage shape이 Claude Code와 달라 자체 parser 보유.
/// versioned incremental parse cache(path+size+mtime key)를 메모리와 Application Support에 유지하는 actor — 소비하는 모든 provider가 shared 인스턴스 하나를 써 pi 로그는 카드당이 아닌 1회만 파싱.
actor PiUsageScanner {
    static let shared = PiUsageScanner()

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("pi"),
        persistence: JSONLScanCachePersistence(namespace: "pi", schemaVersion: 1)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Entry>? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
    }

    /// 파싱된 assistant-message usage line 하나. raw timestamp 유지로 window가 이동해도 cached parse 유효, `cardID`는 parse 시 해석해 집계가 저렴한 filter.
    struct Entry: Codable, Sendable, Equatable {
        var id: String?
        var timestamp: Date
        var cardID: String
        var model: String
        /// pi 자신의 `usage.cost.total` — > 0이면 그대로 사용, nil/0은 엔진 가격 산정으로 fallthrough.
        var carriedCost: Double?
        /// fallthrough 가격 산정용 token bucket.
        var tokens: TokenBreakdown
        /// pi가 보고한 `usage.totalTokens` — 행의 token 수로 표시 (pi 자체 footer와 일치).
        var reportedTotalTokens: Int
    }

    /// 카드 하나에 대해 최근 `daysBack`일의 pi 로그 스캔. sessions 디렉토리에 로그 파일이 전혀 없으면 nil — pi usage 없는 provider는 아무것도 합산하지 않음.
    func scan(cardID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let directory = PiPaths.sessionsDirectory(environment: environment, homeDirectory: homeDirectory())
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let cacheIdentity = directory.resolvingSymlinksInPath().path
        let files = JSONLScanning.jsonlFiles(under: directory)
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: cacheIdentity, parse: Self.parseFile
            )
            return nil
        }

        guard let entries = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: cacheIdentity,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(entries: Self.dedup(entries), cardID: cardID, since: since, pricing: pricing)
    }

    // MARK: - Parsing

    /// session 파일 하나의 매핑된 assistant usage line 전부 파싱. OpenUsage가 추적하지 않는 pi provider의 line은 여기서 drop — 집계에 도달하지 않음.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage":{"#.utf8)
        var entries: [Entry] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard line.range(of: marker) != nil, let entry = parseLine(Data(line)) else { continue }
            entries.append(entry)
        }
        return entries
    }

    static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "message",
              let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let message = object["message"] as? [String: Any],
              message["role"] as? String == "assistant",
              let providerID = message["provider"] as? String,
              let cardID = PiProviderMapping.cardID(forPiProvider: providerID),
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        let cacheWrite = Int(ProviderParse.number(usage["cacheWrite"]) ?? 0)
        let cacheWrite1h = Int(ProviderParse.number(usage["cacheWrite1h"]) ?? 0)
        let tokens = TokenBreakdown(
            input: Int(ProviderParse.number(usage["input"]) ?? 0),
            cacheWrite5m: max(cacheWrite - cacheWrite1h, 0),
            cacheWrite1h: cacheWrite1h,
            cacheRead: Int(ProviderParse.number(usage["cacheRead"]) ?? 0),
            output: Int(ProviderParse.number(usage["output"]) ?? 0)
        )

        let carriedCost = (usage["cost"] as? [String: Any]).flatMap { ProviderParse.number($0["total"]) }
        return Entry(
            id: object["id"] as? String,
            timestamp: timestamp,
            cardID: cardID,
            model: (message["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            carriedCost: carriedCost,
            tokens: tokens,
            reportedTotalTokens: Int(ProviderParse.number(usage["totalTokens"]) ?? 0)
        )
    }

    // MARK: - Dedup and aggregation

    /// fork/clone된 session이 같은 message id로 복제한 replay line 제거, 첫 등장 유지. id 없는 line은 항상 유지.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var seen: Set<String> = []
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            if let id = entry.id, !seen.insert(id).inserted { continue }
            out.append(entry)
        }
        return out
    }

    /// 카드의 entry를 로컬 캘린더 일 단위로 bucket. cost는 pi carried total 우선, 없으면 `pricing`으로 산정 — 산정 불가·cost 없는 모델은 합계에서 제외하고 unknown-model 경고로 표시 (로그 scanner와 동일).
    static func aggregate(entries: [Entry], cardID: String, since: Date, pricing: ModelPricing) -> LogUsageScan {
        var accumulator = DailyUsageAccumulator()
        for entry in entries where entry.cardID == cardID && entry.timestamp >= since {
            let day = DailyUsageAccumulator.dayKey(from: entry.timestamp)
            let trimmedModel = entry.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else if let model = trimmedModel, let estimated = pricing.estimatedCostDollars(model: model, tokens: entry.tokens) {
                cost = estimated
            } else {
                if let model = trimmedModel, entry.reportedTotalTokens > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: modelName)
        }
        return accumulator.build()
    }
}
