import Foundation

/// pi session 로그에서 OpenUsage 카드 하나의 일별 token/cost series 구축 — pi 안에서 발생한 usage(pi로 구동한 Claude sub 등)를 해당 카드의 Usage Trend·spend 타일에 native source와 함께 합산.
/// cost 규칙은 Claude·Codex 로그 scanner와 동일한 `carried cost, else price` — pi의 per-message `usage.cost.total`이 있으면 그대로, `$0`(미산정 구독 usage)이면 공유 엔진으로 가격 산정. usage shape이 Claude Code와 달라 자체 parser 보유.
/// versioned incremental parse cache(path+size+mtime key)를 메모리와 Application Support에 유지하는 actor — 소비하는 모든 provider가 shared 인스턴스 하나를 써 pi 로그는 카드당이 아닌 1회만 파싱.
actor PiUsageScanner {
    static let shared = PiUsageScanner()
    static let cacheSchemaVersion = 9

    enum CostEstimate: Sendable {
        case priced(Double)
        case unpriced
        case unsupportedUsage

        init(_ cost: Double?) {
            self = cost.map(Self.priced) ?? .unpriced
        }
    }

    typealias CostEstimator = @Sendable (String, TokenBreakdown, ModelPricing) -> CostEstimate

    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Entry>

    private static let sharedScanner = IncrementalJSONLScanner<Entry>(
        logTag: LogTag.plugin("pi"),
        persistence: JSONLScanCachePersistence(namespace: "pi", schemaVersion: cacheSchemaVersion)
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

    /// 사용량 기록 하나. timestamp와 카드 귀속을 캐시에 보존.
    struct Entry: Codable, Sendable, Equatable {
        var id: String?
        /// 시각이 손상된 미귀속 사용량은 날짜를 만들지 않고 경고만 보존.
        var timestamp: Date?
        /// 귀속 불가 압축·요약·도구 사용량은 빈 카드 ID로 보존하여 pi 사용량을 읽는 모든 카드에 경고.
        var cardID: String
        var model: String
        /// pi 자신의 `usage.cost.total` — > 0이면 그대로 사용, nil/0은 엔진 가격 산정으로 fallthrough.
        var carriedCost: Double?
        /// fallthrough 가격 산정용 token bucket.
        var tokens: TokenBreakdown
        /// pi가 보고한 `usage.totalTokens` — 행의 token 수로 표시 (pi 자체 footer와 일치).
        var reportedTotalTokens: Int
        /// 손상된 행도 날짜·카드와 함께 캐시에 남겨 cache hit가 정상 빈 이력으로 바뀌는 현상 방지.
        var invalidNumericValues = false
        var invalidMetadata = false
    }

    /// 카드 하나에 대해 최근 `daysBack`일의 pi 로그 스캔. sessions 디렉토리에 로그 파일이 전혀 없으면 nil — pi usage 없는 provider는 아무것도 합산하지 않음.
    func scan(
        cardID: String, daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing,
        costEstimator: CostEstimator? = nil
    ) async -> LogUsageScan? {
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
            onDiskCacheHit: Self.reportRejectedEntries,
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(
            entries: Self.dedup(entries), cardID: cardID, since: since, pricing: pricing,
            costEstimator: costEstimator
        )
    }

    // MARK: - Parsing

    /// 메시지·독립 사용량의 명시적 모델만 사용. 실행 모델이 없는 요약·도구 사용량은 경고로 보존.
    static func parseFile(_ data: Data) -> [Entry] {
        let marker = Data(#""usage""#.utf8)
        var entries: [Entry] = []
        for line in JSONLScanning.lines(in: data) {
            guard line.range(of: marker) != nil, let entry = parseLine(line) else { continue }
            entries.append(entry)
        }
        reportRejectedEntries(entries)
        return entries
    }

    static func parseLine(_ data: Data) -> Entry? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parseObject(object)
    }

    private static func reportRejectedEntries(_ entries: [Entry]) {
        UsageLogNumbers.reportRejectedRows(entries.filter(\.invalidNumericValues).count, source: "pi")
        let rejected = entries.filter(\.invalidMetadata).count
        if rejected > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: "pi",
                localContext: "source=pi; rejected_metadata_rows=\(rejected)"
            )
        }
    }

    private static func parseObject(_ object: [String: Any]) -> Entry? {
        let payload: [String: Any]
        let provider: String
        let model: String
        var invalidMetadata = false
        switch object["type"] as? String {
        case "message":
            guard let message = object["message"] as? [String: Any] else { return nil }
            if message["role"] as? String == "toolResult" {
                return unattributedUsageEntry(object, usage: message["usage"])
            }
            guard message["role"] as? String == "assistant",
                  let recordedProvider = message["provider"] as? String else { return nil }
            payload = message
            provider = recordedProvider
            model = message["responseModel"] as? String ?? message["model"] as? String ?? ""
        case "usage":
            guard let recordedProvider = object["provider"] as? String else { return nil }
            payload = object
            provider = recordedProvider
            model = object["model"] as? String ?? ""
            invalidMetadata = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "compaction", "branch_summary":
            return unattributedUsageEntry(object, usage: object["usage"])
        default:
            return nil
        }
        guard let timestampRaw = object["timestamp"] as? String,
              let timestamp = OpenUsageISO8601.date(from: timestampRaw),
              let cardID = PiProviderMapping.cardID(forPiProvider: provider),
              let usage = payload["usage"] as? [String: Any]
        else { return nil }

        var entry = Entry(
            id: object["id"] as? String,
            timestamp: timestamp,
            cardID: cardID,
            model: model.trimmingCharacters(in: .whitespacesAndNewlines),
            carriedCost: nil,
            tokens: TokenBreakdown(),
            reportedTotalTokens: 0,
            invalidNumericValues: true,
            invalidMetadata: invalidMetadata
        )
        guard let cacheWrite = UsageLogNumbers.count(usage["cacheWrite"], missing: 0),
              let cacheWrite1h = UsageLogNumbers.count(usage["cacheWrite1h"], missing: 0),
              let input = UsageLogNumbers.count(usage["input"], missing: 0),
              let cacheRead = UsageLogNumbers.count(usage["cacheRead"], missing: 0),
              let output = UsageLogNumbers.count(usage["output"], missing: 0),
              let reportedTotal = UsageLogNumbers.count(usage["totalTokens"], missing: 0),
              UsageLogNumbers.sum(input, max(cacheWrite, cacheWrite1h), cacheRead, output) != nil
        else { return entry }
        let tokens = TokenBreakdown(
            input: input,
            cacheWrite5m: max(cacheWrite - cacheWrite1h, 0),
            cacheWrite1h: cacheWrite1h,
            cacheRead: cacheRead,
            output: output
        )

        var carriedCost: Double?
        if let rawCost = usage["cost"] {
            guard let costObject = rawCost as? [String: Any] else { return entry }
            if let rawTotal = costObject["total"] {
                guard let cost = ProviderParse.number(rawTotal), cost >= 0 else { return entry }
                carriedCost = cost
            }
        }
        entry.carriedCost = carriedCost
        entry.tokens = tokens
        entry.reportedTotalTokens = reportedTotal
        entry.invalidNumericValues = false
        return entry
    }

    private static func unattributedUsageEntry(_ object: [String: Any], usage: Any?) -> Entry? {
        guard usage != nil else { return nil }
        return Entry(
            id: object["id"] as? String,
            timestamp: (object["timestamp"] as? String).flatMap(OpenUsageISO8601.date(from:)),
            cardID: "", model: "", carriedCost: nil, tokens: TokenBreakdown(), reportedTotalTokens: 0,
            invalidMetadata: true
        )
    }

    // MARK: - Dedup and aggregation

    private struct EntryIdentity: Hashable {
        let id: String
        let timestamp: Date?
        let cardID: String
    }

    /// 짧은 ID는 세션 안에서만 고유하므로 시각·카드도 같은 사본만 제거. 정상 사본 우선, ID 없는 기록은 유지.
    static func dedup(_ entries: [Entry]) -> [Entry] {
        var indices: [EntryIdentity: Int] = [:]
        var out: [Entry] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            if let id = entry.id {
                let identity = EntryIdentity(id: id, timestamp: entry.timestamp, cardID: entry.cardID)
                if let index = indices[identity] {
                    if (out[index].invalidNumericValues || out[index].invalidMetadata)
                        && !entry.invalidNumericValues && !entry.invalidMetadata { out[index] = entry }
                    continue
                }
                indices[identity] = out.count
            }
            out.append(entry)
        }
        return out
    }

    /// 카드의 entry를 로컬 캘린더 일 단위로 bucket. cost는 pi carried total 우선, 없으면 `pricing`으로 산정 — 산정 불가·cost 없는 모델은 합계에서 제외하고 unknown-model 경고로 표시 (로그 scanner와 동일).
    static func aggregate(
        entries: [Entry], cardID: String, since: Date, pricing: ModelPricing,
        costEstimator: CostEstimator? = nil
    ) -> LogUsageScan {
        let estimate = costEstimator ?? { model, tokens, pricing in
            CostEstimate(pricing.estimatedCostDollars(model: model, tokens: tokens))
        }
        var accumulator = DailyUsageAccumulator()
        var rejectedNumericRows = 0
        var rejectedMetadataRows = 0
        var unsupportedPricingRows = 0
        for entry in entries where entry.cardID == cardID || (entry.invalidMetadata && entry.cardID.isEmpty) {
            if let timestamp = entry.timestamp, timestamp < since { continue }
            guard !entry.invalidMetadata, let timestamp = entry.timestamp else {
                rejectedMetadataRows += 1
                continue
            }
            guard !entry.invalidNumericValues else {
                rejectedNumericRows += 1
                continue
            }
            let day = DailyUsageAccumulator.dayKey(from: timestamp)
            let trimmedModel = entry.model.nilIfEmpty
            let modelName = trimmedModel ?? ModelUsageEntry.unattributedModelName

            let cost: Double
            if let carried = entry.carriedCost, carried > 0 {
                cost = carried
            } else {
                let result = estimate(trimmedModel ?? "", entry.tokens, pricing)
                switch result {
                case .priced(let estimated):
                    cost = estimated
                case .unpriced, .unsupportedUsage:
                    if case .unsupportedUsage = result { unsupportedPricingRows += 1 }
                    if let model = trimmedModel, entry.reportedTotalTokens > 0 {
                        accumulator.addUnknownModel(day: day, model: model)
                    }
                    continue
                }
            }
            accumulator.add(day: day, tokens: entry.reportedTotalTokens, cost: cost, model: modelName)
        }
        return accumulator.build(
            rejectedNumericRows: rejectedNumericRows, source: "pi", unsupportedPricingRows: unsupportedPricingRows,
            rejectedMetadataRows: rejectedMetadataRows
        )
    }
}
