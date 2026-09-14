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

    /// Turn 1개의 token usage — `token_count` line에서 정규화 (delta 적용 완료).
    /// `isFast`는 turn 실행 시점의 fast/priority service tier 여부 — session 자체 log에서 추적, tier metadata 없으면 standard.
    struct Event: Codable, Sendable, Equatable {
        var timestamp: Date
        var model: String
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int
        var isFast: Bool = false
        /// 손상된 행도 캐시에 남겨 cache hit가 정상 빈 이력으로 바뀌는 현상 방지.
        var invalidNumericValues = false
        var pricingModel: String? = nil
    }

    /// 손상된 부모 재생 구간의 불확실한 증가분을 제외하는 형식 — 이전 집계 캐시 재파싱.
    static let cacheSchemaVersion = 6

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

    // MARK: - File parsing

    /// Rollout 파일 1개 파싱 — `turn_context`로 현재 model, `thread_settings_applied`로 service tier 추적, 각 `token_count`(`last_token_usage` 우선, 없으면 누적 `total_token_usage`와의 delta)를 event로 정규화.
    /// Child session의 replay된 parent history는 첫 live `task_started`까지 skip. tier 기록이 없는 session은 standard.
    /// Tier는 session 자체 log에서만 추적 — 현재 `config.toml` 참조 시 toggle이 전체 history를 소급 재산정.
    static func parseFile(_ data: Data) -> [Event] {
        let turnContextMarker = Data(#""type":"turn_context""#.utf8)
        let tokenCountMarker = Data(#""type":"token_count""#.utf8)
        let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
        let taskStartedMarker = Data(#""type":"task_started""#.utf8)
        let threadSettingsMarker = Data(#""type":"thread_settings_applied""#.utf8)

        var events: [Event] = []
        var previousTotals: RawUsage?
        var replayBaselineUnknown = false
        var currentModel: String?
        var currentTierIsFast = false
        var sawSessionMeta = false
        // child session의 replay된 parent history 구간 동안 non-nil.
        var replayGate: ChildReplayGate?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            let isTurnContext = line.range(of: turnContextMarker) != nil
            let isSessionMeta = !sawSessionMeta && line.range(of: sessionMetaMarker) != nil
            let isTaskStarted = replayGate != nil && line.range(of: taskStartedMarker) != nil
            let isThreadSettings = line.range(of: threadSettingsMarker) != nil
            guard isTurnContext || isSessionMeta || isTaskStarted || isThreadSettings
                || line.range(of: tokenCountMarker) != nil
            else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "turn_context" {
                if let model = payload.flatMap(modelName(in:)) {
                    currentModel = model
                }
                continue
            }
            // 파일 자신의 (첫) session_meta만 인정 — child 파일은 자기 것 직후에 parent의 session_meta도 replay.
            if type == "session_meta", !sawSessionMeta {
                sawSessionMeta = true
                if let payload, isChildSessionMeta(payload) {
                    if let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                       let created = OpenUsageISO8601.date(from: timestampRaw) {
                        replayGate = .untilStartedAt(created.timeIntervalSince1970.rounded(.down))
                    } else {
                        // 생성 timestamp가 없어도 child — replay 억제 유지.
                        replayGate = .untilSelfTimedTaskStarted
                    }
                }
                continue
            }
            if isThreadSettings, type == "event_msg",
               payload?["type"] as? String == "thread_settings_applied" {
                if let tier = serviceTier(in: payload) {
                    currentTierIsFast = tier == "fast" || tier == "priority"
                }
                continue
            }
            guard type == "event_msg", let payload else { continue }

            // 첫 live task_started가 child 자신의 turn 시작 — replay된 task_started는 parent의 더 오래된 started_at 유지.
            if payload["type"] as? String == "task_started" {
                if let gate = replayGate,
                   let startedAt = payload["started_at"] as? NSNumber,
                   gate.isCleared(byStartedAt: startedAt.doubleValue, lineTimestamp: object["timestamp"] as? String) {
                    replayGate = nil
                }
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let timestampRaw = (object["timestamp"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let timestamp = OpenUsageISO8601.date(from: timestampRaw)
            else { continue }

            let info = payload["info"] as? [String: Any]
            let totals = (info?["total_token_usage"] as? [String: Any]).map(RawUsage.init(json:))

            // replay된 parent history — delta baseline만 seed, usage 미방출.
            if replayGate != nil {
                if let totals {
                    previousTotals = totals.invalid ? nil : totals
                    replayBaselineUnknown = totals.invalid
                }
                continue
            }

            // 누적 totals 불변이면 Codex가 재방출한 stale snapshot — last_token_usage가 있어도 신규 usage 아님.
            if let totals, !totals.invalid, let previous = previousTotals, totals.equalCounts(previous) {
                continue
            }

            var usage: RawUsage
            // 잘못된 누적값과 정상 last를 섞어 내보내면 다음 totals delta에서 같은 사용량을 재집계.
            if let totals, totals.invalid {
                usage = totals
            } else if let last = (info?["last_token_usage"] as? [String: Any]).map(RawUsage.init(json:)) {
                usage = last
            } else if let totals {
                usage = totals.subtracting(previousTotals)
                // 부모 재생의 기준이 끊겼으면 첫 live 누적값은 새 기준만 설정. 산정 불가한 증가분은 경고로 보존.
                if replayBaselineUnknown { usage.invalid = true }
            } else {
                continue
            }
            // 손상된 totals는 delta baseline으로 쓰지 않음 — 이후 행의 차이까지 오염 방지.
            if let totals, !totals.invalid {
                previousTotals = totals
                replayBaselineUnknown = false
            }
            guard !usage.invalid else {
                events.append(Event(
                    timestamp: timestamp, model: "", input: 0, cached: 0, output: 0, reasoning: 0,
                    total: 0, invalidNumericValues: true
                ))
                continue
            }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { continue }

            let parsedModel = modelName(in: payload) ?? info.flatMap(modelName(in:))
            let model = resolveModel(
                parsed: parsedModel,
                currentModel: &currentModel
            )

            events.append(Event(
                timestamp: timestamp,
                model: model,
                input: usage.input,
                cached: min(usage.cached, usage.input),
                output: usage.output,
                reasoning: usage.reasoning,
                total: usage.total,
                isFast: currentTierIsFast,
                pricingModel: model == autoReviewModel ? autoReviewFallback(at: timestampRaw) : nil
            ))
        }
        UsageLogNumbers.reportRejectedRows(events.filter(\.invalidNumericValues).count, source: "codex")
        return events
    }

    /// `thread_settings_applied` payload의 `service_tier` — `thread_settings` 우선, top-level 표기 허용 (예: `"default"`, `"fast"`, `"priority"`).
    private static func serviceTier(in payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let settings = payload["thread_settings"] as? [String: Any]
        for value in [settings?["service_tier"], payload["service_tier"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// `token_count` usage object의 token 필드 — ccusage가 허용하는 구식 표기(`prompt_tokens`, `completion_tokens`, `cache_read_input_tokens`, …) 수용.
    struct RawUsage: Sendable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int
        var total: Int

        /// 숫자 손상·재생 기준 불확실 — 집계에서 제외하고 경고로 노출.
        var invalid = false

        init(json: [String: Any]) {
            // 먼저 등장한 key가 손상이면 다음 key로 넘어가지 않고 행 자체를 거부.
            func count(_ keys: String...) -> Int? {
                for key in keys where json[key] != nil {
                    return UsageLogNumbers.count(json[key])
                }
                return 0
            }
            guard let input = count("input_tokens", "prompt_tokens", "input"),
                  let cached = count("cached_input_tokens", "cache_read_input_tokens", "cached_tokens"),
                  let output = count("output_tokens", "completion_tokens", "output"),
                  let reasoning = count("reasoning_output_tokens", "reasoning_tokens"),
                  let reported = count("total_tokens"),
                  let recomputed = UsageLogNumbers.sum(input, output, reasoning)
            else {
                self.init(input: 0, cached: 0, output: 0, reasoning: 0, total: 0, invalid: true)
                return
            }
            self.init(
                input: input, cached: cached, output: output, reasoning: reasoning,
                total: (reported > 0 || recomputed == 0) ? reported : recomputed
            )
        }

        private init(input: Int, cached: Int, output: Int, reasoning: Int, total: Int, invalid: Bool = false) {
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning
            self.total = total
            self.invalid = invalid
        }

        /// `other`와 token count 동일 — Codex가 재방출한 불변 누적 snapshot 판정.
        func equalCounts(_ other: RawUsage) -> Bool {
            input == other.input && cached == other.cached && output == other.output
                && reasoning == other.reasoning && total == other.total
        }

        /// 누적 totals에서 turn delta 복원 (`last_token_usage` 부재 시 사용).
        /// 양쪽 모두 검증된 비음수라 차이는 overflow 불가 — 손상 표시만 전파.
        func subtracting(_ previous: RawUsage?) -> RawUsage {
            RawUsage(
                input: max(0, input - (previous?.input ?? 0)),
                cached: max(0, cached - (previous?.cached ?? 0)),
                output: max(0, output - (previous?.output ?? 0)),
                reasoning: max(0, reasoning - (previous?.reasoning ?? 0)),
                total: max(0, total - (previous?.total ?? 0)),
                invalid: invalid || previous?.invalid == true
            )
        }
    }

    private static func modelName(in json: [String: Any]) -> String? {
        for value in [json["model"], json["model_name"], (json["metadata"] as? [String: Any])?["model"]] {
            if let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// Child session의 replay된 parent history를 첫 live turn까지 gate하는 방식.
    private enum ChildReplayGate {
        /// `task_started.started_at`이 child 생성 epoch 이상이면 해제.
        case untilStartedAt(TimeInterval)
        /// 생성 timestamp가 판독 불가한 child용 — `started_at`이 해당 `task_started` line 자신의 wall-clock 초 이상이면 해제 (replay turn은 parent의 더 오래된 `started_at` 유지).
        case untilSelfTimedTaskStarted

        func isCleared(byStartedAt startedAt: TimeInterval, lineTimestamp: String?) -> Bool {
            switch self {
            case .untilStartedAt(let gate):
                return startedAt >= gate
            case .untilSelfTimedTaskStarted:
                guard let raw = lineTimestamp?.trimmingCharacters(in: .whitespaces),
                      let lineDate = OpenUsageISO8601.date(from: raw)
                else { return false }
                return startedAt >= lineDate.timeIntervalSince1970.rounded(.down)
            }
        }
    }

    /// 파일을 child session(subagent spawn 또는 fork)으로 표시하는 session_meta payload — 선행 `token_count` line들은 parent history replay.
    /// JSON `null`은 `NSNull`(Swift `nil` 아님) — null·blank 문자열은 absent 취급, `forked_from_id: null`인 root session의 child 오분류 방지.
    static func isChildSessionMeta(_ payload: [String: Any]) -> Bool {
        if hasNonNullValue(payload["forked_from_id"]) { return true }
        if hasNonNullValue(payload["parent_thread_id"]) { return true }
        if payload["thread_source"] as? String == "subagent" { return true }
        if let source = payload["source"] as? [String: Any], hasNonNullValue(source["subagent"]) {
            return true
        }
        return false
    }

    /// JSONSerialization이 실제 값을 반환했는지 여부 — missing·`null`·blank text 제외.
    private static func hasNonNullValue(_ value: Any?) -> Bool {
        switch value {
        case nil, is NSNull:
            return false
        case let text as String:
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return true
        }
    }

    /// ccusage의 model resolution — line의 명시적 model이 현재 model 갱신, 없으면 추적 중인 model, metadata 전무 시 `gpt-5` fallback.
    static func resolveModel(
        parsed: String?,
        currentModel: inout String?
    ) -> String {
        if let parsed {
            currentModel = parsed
        }
        let model: String
        if let parsed {
            model = parsed
        } else if let current = currentModel {
            model = current
        } else {
            currentModel = "gpt-5"
            model = "gpt-5"
        }
        return model
    }

    private static let autoReviewModel = "codex-auto-review"

    /// 자동 리뷰의 날짜별 추정 단가 참조표 — 실제 백엔드 모델이나 전환일의 확정 기록 아님.
    private static let autoReviewFallbacks: [(releasedOn: String, model: String)] = [
        ("2026-04-23", "gpt-5.5"),
        ("2026-03-05", "gpt-5.4"),
        ("2026-02-05", "gpt-5.3-codex"),
        ("2025-12-11", "gpt-5.2-codex"),
        ("2025-11-13", "gpt-5.1-codex"),
        ("2025-09-15", "gpt-5-codex"),
        ("2025-08-07", "gpt-5")
    ]

    static func autoReviewFallback(at timestamp: String) -> String {
        let date = String(timestamp.prefix(10))
        guard date.count == 10, date.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return "gpt-5"
        }
        return autoReviewFallbacks.first(where: { date >= $0.releasedOn })?.model ?? "gpt-5"
    }

    // MARK: - Aggregation

    private struct EventKey: Hashable {
        var timestamp: Date
        var model: String
        var pricingModel: String?
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
        var accumulator = DailyUsageAccumulator()
        var rejectedNumericRows = 0

        for event in events where event.timestamp >= since {
            guard !event.invalidNumericValues else {
                rejectedNumericRows += 1
                continue
            }
            let key = EventKey(
                timestamp: event.timestamp, model: event.model, pricingModel: event.pricingModel, input: event.input,
                cached: event.cached, output: event.output, reasoning: event.reasoning, total: event.total
            )
            guard seen.insert(key).inserted else { continue }

            let day = DailyUsageAccumulator.dayKey(from: event.timestamp)
            // 경고·내역은 원래 모델명 유지, 자동 리뷰의 날짜별 참조 모델은 가격 계산에만 사용.
            let trimmedModel = event.model.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

            guard let model = trimmedModel else {
                continue
            }
            let pricingModel = event.pricingModel ?? model
            let canonicalModel = pricing.supplement.canonicalName(for: pricingModel) ?? pricingModel
            let isFastAlias = canonicalModel.hasSuffix("-fast")
            let rateModel = isFastAlias ? String(canonicalModel.dropLast("-fast".count)) : canonicalModel

            // Codex 속도는 provider tier — Cursor의 `-fast` 가격 변형 아님. fast alias는 unscaled base rate로 resolve 후 Codex multiplier를 정확히 1회 적용.
            // base entry 없는 third-party fast-only model은 이미 scaled된 rate 유지 — speed multiplier 이중 적용 금지.
            let baseRates = pricing.resolve(model: rateModel)
            let resolvedRates = baseRates ?? pricing.resolve(model: pricingModel)
            guard let rates = resolvedRates else {
                if event.total > 0 {
                    accumulator.addUnknownModel(day: day, model: model)
                }
                continue
            }
            let appliesCodexFastTier = isFastAlias ? baseRates != nil : event.isFast
            let eventCost = cost(
                rates: rates,
                event: event,
                model: rateModel,
                fastTier: appliesCodexFastTier,
                fastMultiplier: codexPriorityMultiplier(for: rateModel, rates: rates)
            )
            accumulator.add(day: day, tokens: event.total, cost: eventCost, model: model)
        }

        return accumulator.build(rejectedNumericRows: rejectedNumericRows, source: "codex")
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
        var effectiveRates = rates
        if let longContext = codexLongContextRates(for: model) {
            effectiveRates.inputAbove200kPerMillion = longContext.input
            effectiveRates.outputAbove200kPerMillion = longContext.output
            effectiveRates.cacheReadAbove200kPerMillion = longContext.cacheRead
            effectiveRates.longContextThresholdTokens = 272_000
        }
        if codexModelHasNoCacheDiscount(model) {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        } else if !rates.cacheReadIsExplicit {
            effectiveRates.cacheReadPerMillion = effectiveRates.inputPerMillion
            effectiveRates.cacheReadAbove200kPerMillion = effectiveRates.inputAbove200kPerMillion
        }
        effectiveRates.fastMultiplier = fastMultiplier

        let nonCached = max(0, event.input - event.cached)
        return effectiveRates.costDollars(for: TokenBreakdown(
            input: nonCached,
            cacheRead: event.cached,
            output: event.output,
            isFast: fastTier
        ))
    }

    /// Codex priority service-tier multiplier — provider 고유 값, supplement의 Cursor `-fast` multiplier 의도적 미사용. 미등재 model은 catalog/fallback 규칙 유지.
    private static func codexPriorityMultiplier(for model: String, rates: ModelRates) -> Double {
        let base = datedBaseModel(model)
        switch base {
        case "gpt-5.5", "gpt-5.5-pro": return 2.5
        case "gpt-5.4", "gpt-5.4-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna": return 2
        default: return rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
    }

    /// OpenAI가 cached-input 할인을 공표하지 않은 Pro model — 구식 bundled catalog에 cache-rate provenance가 없어도 유지하는 provider 규칙.
    private static func codexModelHasNoCacheDiscount(_ model: String) -> Bool {
        switch datedBaseModel(model) {
        case "gpt-5.4-pro", "gpt-5.5-pro": return true
        default: return false
        }
    }

    private static func codexLongContextRates(for model: String) -> (input: Double, output: Double, cacheRead: Double)? {
        switch datedBaseModel(model) {
        case "gpt-5.4": return (5, 22.5, 0.5)
        case "gpt-5.4-pro": return (60, 270, 60)
        case "gpt-5.5": return (10, 45, 1)
        case "gpt-5.5-pro": return (60, 270, 60)
        case "gpt-5.6-sol": return (10, 45, 1)
        case "gpt-5.6-terra": return (4, 18, 0.4)
        case "gpt-5.6-luna": return (0.4, 1.8, 0.04)
        default: return nil
        }
    }

    private static func datedBaseModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
