import Foundation

/// Codex CLI의 일반·Zstandard 세션 원장을 읽어 일별 token/cost 추정.
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
        var reconciliation: LegacyReconciliation? = nil
    }

    /// 갱신된 직전 요청 사용량으로 완료 응답 대조 — 이전 오탐 경고 캐시 재파싱.
    static let cacheSchemaVersion = 20

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
        var seenFiles: Set<String> = []
        let nativeFiles = Self.sessionFiles(homes: homes)
        let files = nativeFiles.files.filter { seenFiles.insert($0.path).inserted }
        let discoveryFailures = nativeFiles.failures
        if discoveryFailures > 0 {
            AppDiagnostics.record(.historyScan, result: .degraded, category: .storage, providerID: "codex",
                                  localContext: "history_discovery_failures=\(discoveryFailures)")
        }
        guard !files.isEmpty else {
            _ = await scanner.items(
                from: [], since: since, cacheIdentity: identity, parse: Self.parseFile
            )
            return discoveryFailures > 0 ? DailyUsageAccumulator().build(readFailureCount: discoveryFailures) : nil
        }

        guard let result = await scanner.scan(
            from: files,
            since: since,
            cacheIdentity: identity,
            onDiskCacheHit: { UsageLogNumbers.reportRejectedRows($0.filter(\.invalidNumericValues).count, source: "codex") },
            parse: { data, path in
                if path.hasSuffix(".jsonl.zst") { return Self.parseFile(try UsageZstandard.decode(data)) }
                return Self.parseFile(data)
            }
        ), !Task.isCancelled else { return nil }
        var scan = Self.aggregate(events: result.items, since: since, pricing: pricing)
        scan.readFailureCount = discoveryFailures + result.failedPaths.count
        return scan
    }

    // MARK: - Discovery

    /// `CODEX_HOME` 단일 경로 우선, 없으면 `~/.codex` 사용.
    private func codexHomes() -> [URL] {
        if let raw = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return [URL(fileURLWithPath: expandHome(raw))]
        }
        return [homeDirectory().appendingPathComponent(".codex")]
    }

    /// 일반·압축 원장 조회. 같은 상대 경로는 활성 사본을, 같은 폴더의 두 형식은 일반 파일을 우선 사용.
    private static func sessionFiles(homes: [URL]) -> UsageFileDiscovery.Result {
        var result = UsageFileDiscovery.Result()
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
            // 발견 경로와 같은 실경로에서 상대 경로 계산.
            for dir in sourceDirs.map({ $0.resolvingSymlinksInPath() }) where seenDirs.insert(dir.path).inserted {
                let discovery = UsageFileDiscovery.files(under: [dir], matching: isRolloutFile)
                result.failures += discovery.failures
                for file in discovery.files {
                    let plainPath = file.path.hasSuffix(".jsonl.zst") ? String(file.path.dropLast(4)) : file.path
                    let relative = plainPath.hasPrefix(dir.path + "/") ? String(plainPath.dropFirst(dir.path.count)) : plainPath
                    guard seenRelative.insert(relative).inserted else { continue }
                    result.files.append(file)
                }
            }
        }
        return result
    }

    private static func isRolloutFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" || (
            url.lastPathComponent.hasSuffix(".jsonl.zst")
                && !FileManager.default.fileExists(atPath: url.deletingPathExtension().path)
        )
    }

    // MARK: - Aggregation

    struct LegacySnapshot: Codable, Sendable, Hashable {
        var scope: String
        var boundary: Int
        var usage: EventKey
    }

    /// 완전 대조되어 잔여량이 없어져도 대응 원장에 원본 구간과 최종 차감 내역 보존.
    struct LegacyReconciliation: Codable, Sendable, Equatable {
        var snapshot: LegacySnapshot
        var recordIDs: Set<String>
    }

    struct EventKey: Codable, Sendable, Hashable {
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

        init(_ event: Event) {
            timestamp = event.timestamp
            model = event.model
            pricingModel = event.pricingModel
            isFast = event.isFast
            isUltrafast = event.isUltrafast
            input = event.input
            cached = event.cached
            output = event.output
            reasoning = event.reasoning
            total = event.total
        }
    }

    /// Event를 local calendar day로 bucket — 파일 간 동일 event(복사된 session log)는 1회 집계, cost는 per-event codex 계산 (`cost` 참고).
    /// 모델 가격이 없으면 측정 토큰을 유지하고 해당 날짜·기간의 비용을 미확정으로 처리.
    static func aggregate(
        events: [Event], since: Date, pricing: ModelPricing
    ) -> LogUsageScan {
        var seen: Set<EventKey> = []
        var seenSnapshots: Set<LegacySnapshot> = []
        var seenRecords: Set<String> = []
        var coverage: [LegacySnapshot: Set<Set<String>>] = [:]
        // 원장 사본의 중복 제거·기간 필터 전에 더 완전한 대조 증거 수집.
        for event in events where !event.invalidNumericValues && !event.invalidMetadata {
            if let reconciliation = event.reconciliation {
                coverage[reconciliation.snapshot, default: []].insert(reconciliation.recordIDs)
            }
        }
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
            if let recordID = event.usageRecordID {
                guard seenRecords.insert(recordID).inserted else { continue }
            } else if let reconciliation = event.reconciliation {
                let replaced = coverage[reconciliation.snapshot, default: []].contains {
                    $0.isStrictSuperset(of: reconciliation.recordIDs)
                }
                guard !replaced, seenSnapshots.insert(reconciliation.snapshot).inserted else { continue }
            } else {
                guard seen.insert(EventKey(event)).inserted else { continue }
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
            let eventCost = costEstimator.estimate(
                model: pricingModel, tokens: tokens, isUltrafast: event.isUltrafast
            )
            if eventCost == nil, event.total > 0 {
                accumulator.addUnknownModel(day: day, model: event.isUltrafast ? model + " (Ultrafast)" : model)
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
