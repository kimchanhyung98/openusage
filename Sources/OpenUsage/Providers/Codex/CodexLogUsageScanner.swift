import Foundation

/// Codex CLI의 local session rollout(`$CODEX_HOME/sessions/**/*.jsonl` + `archived_sessions/`)을 native 스캔해 일별 token/cost 추정 — 외부 `ccusage` CLI의 Codex adapter semantics 이식.
/// 세부 계약은 각 method doc 참고: home 해석(`codexHomes`/`sessionFiles`), line 파싱·child replay gate(`parseFile`), model 해석(`resolveModel`), 집계·cost 계산(`aggregate`/`cost`).
/// Actor인 이유는 `ClaudeLogUsageScanner`와 동일 — 스캔은 main actor 밖 실행, path+size+mtime 기반 versioned Application Support cache로 변경된 파일만 재파싱.
actor CodexLogUsageScanner {
    private let environment: EnvironmentReading
    private let homeDirectory: @Sendable () -> URL
    private let scanner: IncrementalJSONLScanner<Event>
    /// Scoped provider의 안정적 parse-source identity — 서로 다른 계정 카드가 disjoint home 위에서 cache record 공유 금지 (`ClaudeLogUsageScanner` mirror).
    private let cacheIdentityOverride: String?
    /// 추가 계정 카드의 scan을 자기 managed home으로만 고정 — 다른 계정 rollout의 유입 차단. `nil`은 표준 resolution(`CODEX_HOME`, `~/.codex`) 유지.
    private let rootsOverride: [URL]?
    /// 같은 계정의 managed home — 기본 카드의 추가 history root로 병합.
    private let additionalRoots: [URL]

    /// 응답 원장 또는 기존 누적 이벤트에서 정규화한 요청별 토큰.
    /// Fast·Ultrafast는 turn 실행 시점의 service tier — session 자체 log에서 추적, tier metadata 없으면 standard.
    struct Event: Codable, Sendable, Equatable {
        var timestamp: Date
        var model: String
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
        var isFast: Bool = false
        var isUltrafast: Bool = false
        /// 손상된 행도 캐시에 남겨 cache hit가 정상 빈 이력으로 바뀌는 현상 방지.
        var invalidNumericValues = false
        var invalidMetadata = false
        var pricingModel: String? = nil
        var usageRecordID: String? = nil
    }

    /// 개별 요청만 기록된 구간의 누적 기준 수정 — 이전 집계 캐시 재파싱.
    static let cacheSchemaVersion = 16

    /// 같은 Codex home을 해석하는 multi-account 카드가 공유하는 scanner — rollout당 1회 파싱.
    private static let sharedScanner = IncrementalJSONLScanner<Event>(
        logTag: LogTag.plugin("codex"),
        persistence: JSONLScanCachePersistence(namespace: "codex", schemaVersion: cacheSchemaVersion)
    )

    static func flushPersistentCacheWrites() async {
        await sharedScanner.flushPendingWrites()
    }

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        incrementalScanner: IncrementalJSONLScanner<Event>? = nil,
        cacheIdentityOverride: String? = nil,
        rootsOverride: [URL]? = nil,
        additionalRoots: [URL] = []
    ) {
        precondition(cacheIdentityOverride?.isEmpty != true)
        // scoped root set은 자체 parse-source identity 필수 — 표준 identity로는 기본 카드와 cache record 충돌.
        precondition(rootsOverride == nil || cacheIdentityOverride != nil)
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.scanner = incrementalScanner ?? Self.sharedScanner
        self.cacheIdentityOverride = cacheIdentityOverride
        self.rootsOverride = rootsOverride
        self.additionalRoots = additionalRoots
    }

    /// 최근 `daysBack`일의 Codex rollout 스캔 — Codex home 또는 session 파일이 없으면 `nil` (spend tile은 "No data").
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        let homes = rootsOverride ?? codexHomes() + additionalRoots
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        // scoped 카드는 안정적 per-card identity, 표준 walk는 resolve된 home set을 cache key로 사용 (`ClaudeLogUsageScanner.parseCacheIdentity` 참고).
        let identity: String
        if let cacheIdentityOverride {
            identity = cacheIdentityOverride
        } else {
            let identityPaths = Set(homes.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
                .sorted()
            identity = identityPaths.isEmpty ? "no-codex-home" : identityPaths.joined(separator: "\n")
        }
        let files = Self.sessionFiles(homes: homes)
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: identity, parse: Self.parseFile
            )
            return nil
        }

        guard let events = await scanner.items(
            from: files,
            since: since,
            cacheIdentity: identity,
            onDiskCacheHit: { UsageLogNumbers.reportRejectedRows($0.filter(\.invalidNumericValues).count, source: "codex") },
            parse: Self.parseFile
        ), !Task.isCancelled else { return nil }
        return Self.aggregate(events: events, since: since, pricing: pricing)
    }

    // MARK: - Discovery

    /// `CODEX_HOME` entry(comma 구분) 우선, 없으면 `~/.codex` — ccusage와 동일.
    private func codexHomes() -> [URL] {
        if let raw = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: expandHome($0)) }
        }
        return [homeDirectory().appendingPathComponent(".codex")]
    }

    /// 각 home의 `sessions/`·`archived_sessions/` 아래 모든 rollout `*.jsonl` (둘 다 없으면 home 직접 스캔 — ccusage fallback).
    /// 같은 relative path는 `sessions/` 사본 우선 — archived 중복의 이중 집계 금지.
    private static func sessionFiles(homes: [URL]) -> [JSONLScanning.DiscoveredFile] {
        var files: [JSONLScanning.DiscoveredFile] = []
        var seenDirs: Set<String> = []
        for home in homes {
            var seenRelative: Set<String> = []
            var sourceDirs: [URL] = []
            for name in ["sessions", "archived_sessions"] {
                let dir = home.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    sourceDirs.append(dir)
                }
            }
            if sourceDirs.isEmpty {
                sourceDirs = [home]
            }
            // `jsonlFiles`가 enumerate 전에 symlink를 resolve — 여기서도 resolve해야 symlinked home에서 relative key와 cross-home dir dedup이 일치.
            for dir in sourceDirs.map({ $0.resolvingSymlinksInPath() }) where seenDirs.insert(dir.path).inserted {
                for file in JSONLScanning.jsonlFiles(under: dir) {
                    let relative = String(file.path.dropFirst(dir.path.count))
                    guard seenRelative.insert(relative).inserted else { continue }
                    files.append(file)
                }
            }
        }
        return files
    }

    // MARK: - Aggregation

    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var pricingModel: String?
        var isFast: Bool
        var isUltrafast: Bool
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
    }

    /// Event를 local calendar day로 bucket — 파일 간 동일 event(복사된 session log)는 1회 집계, cost는 per-event codex 계산 (`cost` 참고).
    /// Pricing 불가 event(unknown model, blank slug)는 모든 표시 합계(token·dollar·trend·model breakdown)에서 제외 — 측정값과 pricing 불가 값의 혼합 방지.
    /// unknown model 이름은 `unknownModelsByDay`(tile의 경고 triangle)로만 노출; blank slug는 unattributed — 경고할 이름 자체가 없음.
    static func aggregate(
        events: [Event], since: Date, pricing: ModelPricing
    ) -> LogUsageScan {
        var seen: Set<EventKey> = []
        var seenRecords: Set<String> = []
        let recordedKeys = Set(events.lazy.filter {
            $0.usageRecordID != nil && !$0.invalidNumericValues && !$0.invalidMetadata && $0.timestamp >= since
        }.map { event in
            EventKey(
                timestamp: event.timestamp, model: event.model, pricingModel: event.pricingModel,
                isFast: event.isFast, isUltrafast: event.isUltrafast, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total
            )
        })
        var accumulator = DailyUsageAccumulator()
        var rejectedNumericRows = 0
        var rejectedMetadataRows = 0
        var costEstimator = CodexUsagePricing.Resolver(pricing: pricing)

        for event in events where event.timestamp >= since {
            guard !event.invalidMetadata else {
                rejectedMetadataRows += 1
                continue
            }
            guard !event.invalidNumericValues else {
                rejectedNumericRows += 1
                continue
            }
            let key = EventKey(
                timestamp: event.timestamp, model: event.model, pricingModel: event.pricingModel,
                isFast: event.isFast, isUltrafast: event.isUltrafast, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total
            )
            if let recordID = event.usageRecordID {
                guard seenRecords.insert(recordID).inserted else { continue }
            } else {
                guard !recordedKeys.contains(key), seen.insert(key).inserted else { continue }
            }

            let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
            // 경고·내역은 원래 모델명 유지, 자동 리뷰의 날짜별 참조 모델은 가격 계산에만 사용.
            let trimmedModel = event.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            guard let model = trimmedModel else {
                continue
            }
            let tokens = TokenBreakdown(
                input: max(0, event.input - event.cached), cacheRead: event.cached,
                output: event.output, isFast: event.isFast
            )
            let pricingModel = event.pricingModel ?? model
            guard
                let eventCost = costEstimator.estimate(
                    model: pricingModel, tokens: tokens, isUltrafast: event.isUltrafast
                )
            else {
                if event.total > 0 {
                    accumulator.addUnknownModel(day: day, model: event.isUltrafast ? model + " (Ultrafast)" : model)
                }
                continue
            }
            accumulator.add(day: day, tokens: event.total, cost: eventCost, model: model)
        }

        if rejectedMetadataRows > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: "codex",
                localContext: "source=codex; invalid_metadata_rows=\(rejectedMetadataRows)"
            )
        }
        return accumulator.build(
            rejectedNumericRows: rejectedNumericRows, source: "codex", rejectedMetadataRows: rejectedMetadataRows
        )
    }

    /// Codex cost 계산 (ccusage 방식) — non-cached input은 input rate, cached input은 명시적 cache-read rate(할인 미공표 시 full input rate), output(reasoning 포함)은 output rate.
    /// 지원 OpenAI model은 272k 초과 시 request 전체를 상위 rate로 전환.
    static func cost(
        rates: ModelRates,
        event: Event,
        model: String,
        fastTier: Bool,
        fastMultiplier: Double
    ) -> Double {
        var effectiveRates = CodexUsagePricing.adjusted(rates: rates, model: model)
        effectiveRates.fastMultiplier = fastMultiplier
        return effectiveRates.costDollars(for: TokenBreakdown(
            input: max(0, event.input - event.cached),
            cacheRead: event.cached,
            output: event.output,
            isFast: fastTier
        ))
    }
}
