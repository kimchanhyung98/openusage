import Foundation

extension CodexLogUsageScanner {
    // MARK: - File parsing

    /// 응답 원장과 대응하는 누적 증가분만 중복 제외. 원장에 없는 소비는 기존 이벤트로 복원.
    /// Child session의 replay된 parent history는 첫 live `task_started`까지 skip. tier 기록이 없는 session은 standard.
    /// Tier는 session 자체 log에서만 추적 — 현재 `config.toml` 참조 시 toggle이 전체 history를 소급 재산정.
    static func parseFile(_ data: Data) -> [Event] {
        let turnContextMarker = Data(#""type":"turn_context""#.utf8)
        let tokenCountMarker = Data(#""type":"token_count""#.utf8)
        let usageRecordMarker = Data(#""type":"token_usage_record""#.utf8)
        let compactedMarker = Data(#""type":"compacted""#.utf8)
        let sessionMetaMarker = Data(#""type":"session_meta""#.utf8)
        let taskStartedMarker = Data(#""type":"task_started""#.utf8)
        let threadSettingsMarker = Data(#""type":"thread_settings_applied""#.utf8)
        let taskCompleteMarker = Data(#""type":"task_complete""#.utf8)
        let turnAbortedMarker = Data(#""type":"turn_aborted""#.utf8)

        var events: [Event] = []
        var legacyScopes: [Int: (scope: String, boundary: Int, modelOverride: String?)] = [:]
        var recordedEvents: [Int: (scope: String, boundary: Int, responseID: String)] = [:]
        var invalidBoundaries: [String: Set<Int>] = [:]
        var seenRecords: Set<String> = []
        var compactionBoundaries: [String: Int] = [:]
        var failedBoundaries: [String: Int] = [:]
        var usageBoundary = 0
        var currentTurnID: String?
        var contextSequence = 0
        var turnContexts: [String: (model: String?, fast: Bool, ultrafast: Bool)] = [:]
        var previousTotals: RawUsage?
        var cumulativeBaselineUnknown = false
        var currentModel: String?
        var currentTierIsFast = false
        var currentTierIsUltrafast = false
        var sawSessionMeta = false
        // child session의 replay된 parent history 구간 동안 non-nil.
        var replayGate: ChildReplayGate?

        for line in JSONLScanning.lines(in: data) {
            let isTurnContext = line.range(of: turnContextMarker) != nil
            let isSessionMeta = !sawSessionMeta && line.range(of: sessionMetaMarker) != nil
            let isTaskStarted = line.range(of: taskStartedMarker) != nil
            let isThreadSettings = line.range(of: threadSettingsMarker) != nil
            guard isTurnContext || isSessionMeta || isTaskStarted || isThreadSettings
                || line.range(of: tokenCountMarker) != nil
                || line.range(of: usageRecordMarker) != nil
                || line.range(of: compactedMarker) != nil
                || line.range(of: taskCompleteMarker) != nil
                || line.range(of: turnAbortedMarker) != nil
            else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }

            let type = object["type"] as? String
            let payload = object["payload"] as? [String: Any]

            if type == "compacted" {
                if let responseID = payload?["compaction_response_id"] as? String {
                    compactionBoundaries[responseID] = usageBoundary
                }
                continue
            }

            if type == "turn_context" {
                currentTurnID = (payload?["turn_id"] as? String)?.nilIfEmpty
                contextSequence += 1
                if let model = payload.flatMap(modelName(in:)) {
                    currentModel = model
                }
                if let currentTurnID {
                    turnContexts[currentTurnID] = (currentModel, currentTierIsFast, currentTierIsUltrafast)
                }
                continue
            }
            // 파일 자신의 (첫) session_meta만 인정 — child 파일은 자기 것 직후에 parent의 session_meta도 replay.
            if type == "session_meta", !sawSessionMeta {
                sawSessionMeta = true
                if let payload, isChildSessionMeta(payload) {
                    previousTotals = nil
                    cumulativeBaselineUnknown = true
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
                    currentTierIsUltrafast = tier == "ultrafast"
                }
                let settings = payload?["thread_settings"] as? [String: Any]
                if let currentTurnID {
                    let model = settings.flatMap(modelName(in:)) ?? payload.flatMap(modelName(in:)) ?? currentModel
                    turnContexts[currentTurnID] = (model, currentTierIsFast, currentTierIsUltrafast)
                }
                continue
            }
            if type == "token_usage_record", let payload, replayGate == nil,
               let timestampRaw = object["timestamp"] as? String,
               let timestamp = OpenUsageISO8601.date(from: timestampRaw) {
                let turnID = (payload["turn_id"] as? String)?.nilIfEmpty
                let sessionID = (payload["session_id"] as? String)?.nilIfEmpty
                let responseID = (payload["response_id"] as? String)?.nilIfEmpty
                let scope = currentTurnID.map { "turn:" + (turnID ?? $0) } ?? "context:\(contextSequence)"
                let raw = payload["usage"] as? [String: Any]
                let usage = RawUsage(json: raw ?? [:])
                guard let sessionID, let responseID, turnID != nil,
                      raw?["input_tokens"] != nil, raw?["output_tokens"] != nil,
                      raw?["total_tokens"] != nil, !usage.invalid else {
                    invalidBoundaries[scope, default: []].insert(usageBoundary)
                    events.append(Event(timestamp: timestamp, model: "", input: 0, cached: 0, output: 0,
                                        reasoning: 0, total: 0, invalidNumericValues: true))
                    continue
                }
                let recordID = sessionID + ":" + responseID
                guard usage.total > 0, seenRecords.insert(recordID).inserted else { continue }
                let context = turnID.flatMap { turnContexts[$0] }
                    ?? (currentModel, currentTierIsFast, currentTierIsUltrafast)
                let model = context.model ?? "gpt-5"
                recordedEvents[events.count] = (scope, usageBoundary, responseID)
                events.append(Event(
                    timestamp: timestamp, model: model, input: usage.input, cached: min(usage.cached, usage.input),
                    output: usage.output, reasoning: usage.reasoning, total: usage.total,
                    isFast: context.fast, isUltrafast: context.ultrafast,
                    pricingModel: model == autoReviewModel ? autoReviewFallback(at: timestampRaw) : nil,
                    usageRecordID: recordID
                ))
                continue
            }
            guard type == "event_msg", let payload else { continue }
            if ["task_complete", "turn_aborted"].contains(payload["type"] as? String ?? ""),
               payload["error"] is [String: Any], replayGate == nil {
                let turnID = (payload["turn_id"] as? String)?.nilIfEmpty ?? currentTurnID
                failedBoundaries[turnID.map { "turn:" + $0 } ?? "context:\(contextSequence)"] = usageBoundary
                continue
            }

            // 첫 live task_started가 child 자신의 turn 시작 — replay된 task_started는 parent의 더 오래된 started_at 유지.
            if payload["type"] as? String == "task_started" {
                if let turnID = (payload["turn_id"] as? String)?.nilIfEmpty { currentTurnID = turnID }
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
            // live 누적값이 같은 재방출은 모델도 되돌리지 않음. replay 메타데이터는 아래에서 복원.
            if replayGate == nil, let totals, !totals.invalid,
               let previous = previousTotals, totals.equalCounts(previous) {
                continue
            }
            let modelOverride = modelName(in: payload) ?? info.flatMap(modelName(in:))
            if let parsedModel = modelOverride {
                currentModel = parsedModel
                if let currentTurnID {
                    turnContexts[currentTurnID] = (parsedModel, currentTierIsFast, currentTierIsUltrafast)
                }
            }

            // replay된 parent history — delta baseline만 seed, usage 미방출.
            if replayGate != nil {
                if payload["info"] == nil || payload["info"] is NSNull { continue }
                previousTotals = totals.flatMap { $0.invalid ? nil : $0 }
                cumulativeBaselineUnknown = previousTotals == nil
                continue
            }

            var usage: RawUsage
            // 잘못된 누적값과 정상 last를 섞어 내보내면 다음 totals delta에서 같은 사용량을 재집계.
            if let totals, totals.invalid {
                usage = totals
            } else if let last = (info?["last_token_usage"] as? [String: Any]).map(RawUsage.init(json:)) {
                if !last.invalid, let totals, let previousTotals, totals.isAtLeast(previousTotals) {
                    usage = totals.subtracting(previousTotals)
                } else {
                    usage = last
                }
            } else if let totals {
                usage = totals.subtracting(previousTotals)
                // 누적 기준이 끊겼으면 새 기준만 설정. 산정 불가한 증가분은 경고로 보존.
                if cumulativeBaselineUnknown { usage.invalid = true }
            } else {
                continue
            }
            let boundary = usageBoundary
            usageBoundary += 1
            // 손상된 totals는 delta baseline으로 쓰지 않음 — 이후 행의 차이까지 오염 방지.
            if let totals, !totals.invalid {
                previousTotals = totals
                cumulativeBaselineUnknown = false
            }
            guard !usage.invalid else {
                legacyScopes[events.count] = (currentTurnID.map { "turn:" + $0 } ?? "context:\(contextSequence)", boundary, modelOverride)
                events.append(Event(
                    timestamp: timestamp, model: "", input: 0, cached: 0, output: 0, reasoning: 0,
                    total: 0, invalidNumericValues: true
                ))
                continue
            }
            guard usage.input > 0 || usage.cached > 0 || usage.output > 0 || usage.reasoning > 0 else { continue }
            if totals == nil {
                previousTotals = nil
                cumulativeBaselineUnknown = true
            }

            let model = resolveModel(
                parsed: nil,
                currentModel: &currentModel
            )

            legacyScopes[events.count] = (currentTurnID.map { "turn:" + $0 } ?? "context:\(contextSequence)", boundary, modelOverride)
            events.append(
                Event(
                    timestamp: timestamp,
                    model: model,
                    input: usage.input,
                    cached: min(usage.cached, usage.input),
                    output: usage.output,
                    reasoning: usage.reasoning,
                    total: usage.total,
                    isFast: currentTierIsFast,
                    isUltrafast: currentTierIsUltrafast,
                    pricingModel: model == autoReviewModel ? autoReviewFallback(at: timestampRaw) : nil
                ))
        }
        let recordsByBoundary = Dictionary(grouping: recordedEvents.keys.sorted()) { recordedEvents[$0]!.boundary }
        var matchedRecords: Set<Int> = []
        let retainedIndices = events.indices.filter { index in
            let event = events[index]
            guard let legacy = legacyScopes[index] else { return true }
            guard invalidBoundaries[legacy.scope]?.contains(legacy.boundary) != true else { return false }
            guard !event.invalidNumericValues else { return true }
            var remaining = event
            let nextRecords = recordsByBoundary[legacy.boundary + 1] ?? []
            let hasPendingRecord = invalidBoundaries[legacy.scope]?.contains(legacy.boundary + 1) == true
                || nextRecords.contains { recordedEvents[$0]!.scope == legacy.scope }
            let candidates = (recordsByBoundary[legacy.boundary] ?? []) + nextRecords
            for recordIndex in candidates {
                let record = recordedEvents[recordIndex]!
                guard record.scope == legacy.scope, !matchedRecords.contains(recordIndex) else { continue }
                // 원격 압축은 설치 뒤 누적값 재계산, 로컬 압축은 사용량 발행 뒤 설치.
                let compactedAt = compactionBoundaries[record.responseID]
                if let compactedAt, compactedAt <= legacy.boundary { continue }
                // 실패한 압축 원장은 설치 마커가 없어 같은 구간의 중단 응답과 대응 확정 불가.
                if compactedAt == nil, record.boundary == legacy.boundary,
                   failedBoundaries[legacy.scope] == legacy.boundary + 1, !hasPendingRecord {
                    remaining.invalidMetadata = true
                    events[index] = remaining
                    return true
                }
                let usage = events[recordIndex]
                let sameUsage = usage.input == remaining.input && usage.cached == remaining.cached
                    && usage.output == remaining.output && usage.reasoning == remaining.reasoning
                    && usage.total == remaining.total
                // 역순 원장은 같은 시각·사용량의 바로 앞 이벤트에 대응하며 한 구간에서만 차감.
                let reversed = compactedAt == nil
                    && record.boundary == legacy.boundary + 1
                    && usage.timestamp == event.timestamp && (usage.model == event.model || legacy.modelOverride != nil)
                    && usage.isFast == event.isFast && usage.isUltrafast == event.isUltrafast
                    && sameUsage
                guard record.boundary == legacy.boundary || reversed,
                      remaining.input >= usage.input, remaining.cached >= usage.cached,
                      remaining.output >= usage.output, remaining.reasoning >= usage.reasoning,
                      remaining.total >= usage.total else { continue }
                if sameUsage, let model = legacy.modelOverride {
                    events[recordIndex].model = model
                    events[recordIndex].pricingModel = model == autoReviewModel
                        ? autoReviewFallback(at: OpenUsageISO8601.string(from: usage.timestamp)) : nil
                }
                matchedRecords.insert(recordIndex)
                remaining.input -= usage.input
                remaining.cached -= usage.cached
                remaining.output -= usage.output
                remaining.reasoning -= usage.reasoning
                remaining.total -= usage.total
            }
            events[index] = remaining
            return remaining.input > 0 || remaining.cached > 0 || remaining.output > 0 || remaining.reasoning > 0
        }
        let selected = retainedIndices.map { events[$0] }
        UsageLogNumbers.reportRejectedRows(selected.filter(\.invalidNumericValues).count, source: "codex")
        return selected
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

        func isAtLeast(_ other: RawUsage) -> Bool {
            input >= other.input && cached >= other.cached && output >= other.output
                && reasoning >= other.reasoning && total >= other.total
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

}
