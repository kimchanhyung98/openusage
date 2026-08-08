import Foundation

struct CursorMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Cursor의 untyped `usage` payload에서 3개 plan-usage 결정(map guard, request-based fallback, generic fallback)이 읽는 사실들.
/// 한곳에서 1회 decode — predicate들이 어긋나지 않게 함(과거 두 파일에 같은 검사가 중복).
struct CursorPlanUsageFacts {
    /// `usage.enabled`는 명시적 `false`일 때만 "off" — 부재는 enabled로 해석.
    let isEnabled: Bool
    let hasPlanUsage: Bool
    /// 숫자일 때의 `planUsage.limit`.
    let limit: Double?
    /// 숫자일 때의 `planUsage.totalPercentUsed`.
    let totalPercentUsed: Double?
    /// 소문자화한 `spendLimitUsage.limitType`.
    let spendLimitType: String?
    /// `spendLimitUsage.pooledLimit` (부재 시 0).
    let pooledLimit: Double

    init(usage: [String: Any]) {
        isEnabled = usage["enabled"] as? Bool != false
        let planUsage = usage["planUsage"] as? [String: Any]
        hasPlanUsage = planUsage != nil
        limit = planUsage.flatMap { ProviderParse.number($0["limit"]) }
        totalPercentUsed = planUsage.flatMap { ProviderParse.number($0["totalPercentUsed"]) }
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        spendLimitType = (spendLimitUsage?["limitType"] as? String)?.lowercased()
        pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
    }

    var hasLimit: Bool { limit != nil }
    var hasTotalUsagePercent: Bool { totalPercentUsed != nil }
    /// `planUsage`는 있으나 쓸 만한 limit 없음 — fallback들이 기준 삼는 "존재하나 무용" 상태.
    var planUsageLimitMissing: Bool { hasPlanUsage && !hasLimit }
    var planUsageUnusable: Bool { !hasPlanUsage || planUsageLimitMissing }
    /// plan 이름과 무관하게 spend-limit 형태만으로 추론한 team 계정.
    var isTeamByShape: Bool { spendLimitType == "team" || pooledLimit > 0 }
    /// generic request-based fallback 트리거: limit도 total-percent도 없는 `planUsage`를 가진 enabled 계정.
    var shouldTryGenericRequestFallback: Bool {
        isEnabled && hasPlanUsage && !hasLimit && !hasTotalUsagePercent
    }
}

enum CursorUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageAfterRefreshFailed
    case requestBasedUnavailable(String)
    case totalUsageLimitMissing
    case noActiveSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .usageAfterRefreshFailed:
            return "Usage request failed after refresh. Try again."
        case .requestBasedUnavailable(let message):
            return message
        case .totalUsageLimitMissing:
            return "Total usage limit missing from API response."
        case .noActiveSubscription:
            return "No active Cursor subscription."
        }
    }
}

enum CursorUsageMapper {
    static let billingPeriodMs = MetricPeriod.monthMs

    static func mapUsage(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> CursorMappedUsage {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            throw CursorUsageError.noActiveSubscription
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        guard facts.hasLimit || facts.hasTotalUsagePercent else {
            throw CursorUsageError.totalUsageLimitMissing
        }

        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let planUsedCents = ProviderParse.number(planUsage["totalSpend"])
            ?? ((facts.limit ?? 0) - (ProviderParse.number(planUsage["remaining"]) ?? 0))
        let computedPercentUsed = facts.limit.flatMap { limit -> Double? in
            guard limit > 0 else { return nil }
            return planUsedCents / limit * 100
        } ?? 0
        let totalUsagePercent = facts.totalPercentUsed ?? computedPercentUsed

        let cycle = billingCycle(from: usage)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let isTeamAccount = normalizedPlan == "team" || facts.isTeamByShape

        if isTeamAccount {
            guard let limitCents = facts.limit else {
                throw CursorUsageError.requestBasedUnavailable("Cursor request-based usage data unavailable. Try again later.")
            }
            lines.append(.progress(
                label: "Total usage",
                used: ProviderParse.centsToDollars(planUsedCents),
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        } else {
            lines.append(.progress(
                label: "Total usage",
                used: totalUsagePercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let autoPercentUsed = ProviderParse.number(planUsage["autoPercentUsed"]) {
            lines.append(.progress(
                label: "Auto usage",
                used: autoPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let apiPercentUsed = ProviderParse.number(planUsage["apiPercentUsed"]) {
            lines.append(.progress(
                label: "API usage",
                used: apiPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let spendLimitUsage {
            let limit = ProviderParse.number(spendLimitUsage["individualLimit"]) ?? ProviderParse.number(spendLimitUsage["pooledLimit"]) ?? 0
            let remaining = ProviderParse.number(spendLimitUsage["individualRemaining"]) ?? ProviderParse.number(spendLimitUsage["pooledRemaining"]) ?? 0
            let spent = onDemandSpendCents(from: spendLimitUsage, limit: limit, remaining: remaining)
            if limit > 0 {
                lines.append(.progress(
                    label: "On-demand",
                    used: ProviderParse.centsToDollars(spent),
                    limit: ProviderParse.centsToDollars(limit),
                    format: .dollars
                ))
            } else if spent > 0 {
                lines.append(.values(
                    label: "On-demand",
                    values: [MetricValue(number: ProviderParse.centsToDollars(spent), kind: .dollars)]
                ))
            }
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    private static func onDemandSpendCents(from spendLimitUsage: [String: Any], limit: Double, remaining: Double) -> Double {
        let reported = [
            ProviderParse.number(spendLimitUsage["individualUsed"]),
            ProviderParse.number(spendLimitUsage["pooledUsed"]),
            ProviderParse.number(spendLimitUsage["totalSpend"])
        ].compactMap { $0 }
        if let positive = reported.first(where: { $0 > 0 }) {
            return positive
        }
        let inferred = max(0, limit - remaining)
        return inferred > 0 ? inferred : (reported.first ?? 0)
    }

    static func mapRequestBasedUsage(
        _ usage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        var lines: [MetricLine] = []
        if let gpt4 = usage?["gpt-4"] as? [String: Any],
           let limit = ProviderParse.number(gpt4["maxRequestUsage"]),
           limit > 0 {
            let used = ProviderParse.number(gpt4["numRequests"]) ?? 0
            let cycleStart = (usage?["startOfMonth"] as? String).flatMap(OpenUsageISO8601.date(from:))
            lines.append(.progress(
                label: "Requests",
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                resetsAt: cycleStart?.addingTimeInterval(TimeInterval(billingPeriodMs) / 1000),
                periodDurationMs: billingPeriodMs
            ))
        }

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    static func shouldUseRequestBasedFallback(
        usage: [String: Any],
        planName: String?,
        planInfoUnavailable: Bool
    ) -> (shouldFallback: Bool, message: String) {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled else {
            return (false, "")
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if facts.planUsageUnusable && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && !facts.hasTotalUsagePercent && normalizedPlan.isEmpty && planInfoUnavailable {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        if facts.isTeamByShape && facts.planUsageLimitMissing {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        return (false, "")
    }

    /// Cursor CSV 행에서 공용 Today / Yesterday / Last 30 Days spend 타일 추가. 행을 로컬 캘린더 일 단위 `DailyUsageSeries`로 집계해 Claude/Codex/Grok 타일과 같은 `SpendTileMapper`에 전달 — source note만 다르고 출력 동일. cost는 export된 token 수로 로컬 계산이라 달러 값에 추정 아이콘.
    /// 모델 breakdown 행은 raw CSV slug가 아닌 base 모델로 그룹화 — Cursor는 thinking effort/fast 조합마다 slug를 export해 근사 중복 행이 실제 순위를 가림. supplement의 alias rule이 slug를 canonical pricing key로 축약하고 `-fast` canonical은 base로 흡수. raw slug는 `variants`로 생존 — 행 tooltip의 effort별 breakdown.
    static func appendSpendLines(
        rows: [CursorUsageCSVRow],
        now: Date,
        pricing: ModelPricing,
        to lines: inout [MetricLine]
    ) -> ProviderUsageHistory {
        let calendar = Calendar.current
        var costByDay: [String: Double] = [:]
        var tokensByDay: [String: Int] = [:]
        var modelsByDay: [String: [String: ModelAccumulator]] = [:]
        // pricing source가 가격을 모르는 행(nil imputed cost)은 모든 표시 합계(tokens·달러·trend·모델 breakdown)에서 제외 — 측정 tokens와 unpriceable tokens를 섞으면 수치가 모순됨. 모델명은 경고 삼각형으로만 노출 — 일 단위로 추적해 spend 타일이 수치 불완전을 경고. 실제 tokens를 쓴 행만 집계 — unknown 모델의 0-token 행은 아무것도 바꾸지 않아 표시할 가치 없음.
        var unknownModelsByDay: [String: Set<String>] = [:]
        for row in rows {
            let day = DailyUsageAccumulator.dayKey(from: row.date, calendar: calendar)
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let cost = row.imputedCostDollars else {
                if row.tokens.totalTokens > 0, !model.isEmpty {
                    unknownModelsByDay[day, default: []].insert(model)
                }
                continue
            }
            costByDay[day, default: 0] += cost
            tokensByDay[day, default: 0] += row.tokens.totalTokens
            let modelName = model.isEmpty ? ModelUsageEntry.unattributedModelName : model
            let family = model.isEmpty ? modelName : familyName(for: model, pricing: pricing)
            modelsByDay[day, default: [:]][family, default: ModelAccumulator()].add(
                variant: modelName,
                tokens: row.tokens.totalTokens,
                costUSD: cost
            )
        }

        // 일별 raw 달러 합산 후 마지막에 한 번만 센트 단위로 snap — 행마다 반올림하면 바쁜 날 sub-cent drift 누적.
        let daily = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(
                date: day,
                totalTokens: tokensByDay[day] ?? 0,
                costUSD: ((costByDay[day] ?? 0) * 100).rounded() / 100
            )
        }
        let series = DailyUsageSeries(daily: daily)
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                models: modelsByDay[day, default: [:]].map { model, accumulator in
                    accumulator.entry(model: model)
                }
            )
        })
        SpendTileMapper.appendTokenUsage(series, to: &lines, now: now, estimated: true,
                                         unknownModelsByDay: unknownModelsByDay,
                                         modelUsage: modelUsage,
                                         modelSourceNote: "From your Cursor usage export")
        // Cursor tokens는 로컬 CLI 로그가 아닌 server export CSV에서 옴 — trend note는 로그 스캔 provider들의 "estimated from local logs" 대신 그 source를 명시. tokens는 어느 쪽이든 측정값.
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: "From your Cursor usage export")
        return ProviderUsageHistory(
            series: series,
            modelUsage: modelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
    }

    /// raw CSV slug의 표시 family: canonical pricing key에서 `-fast` suffix를 base로 흡수(`gpt-5.5-extra-high-fast` → `gpt-5.5-fast` → `gpt-5.5`). alias rule이 모르는 slug는 raw 이름 유지 — 잘못된 추측은 무관한 모델을 조용히 병합.
    private static func familyName(for model: String, pricing: ModelPricing) -> String {
        let canonical = pricing.supplement.canonicalName(for: model) ?? model
        guard canonical.hasSuffix("-fast") else { return canonical }
        let base = String(canonical.dropLast("-fast".count))
        return base.isEmpty ? canonical : base
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?
        var variants: [String: (tokens: Int, costUSD: Double?)] = [:]

        mutating func add(variant: String, tokens: Int, costUSD: Double?) {
            self.tokens += tokens
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
            }
            let existing = variants[variant] ?? (0, nil)
            let combinedCost: Double? = costUSD.map { (existing.costUSD ?? 0) + $0 } ?? existing.costUSD
            variants[variant] = (existing.tokens + tokens, combinedCost)
        }

        func entry(model: String) -> ModelUsageEntry {
            // family 자신의 이름을 가진 단일 variant는 breakdown이 아님 — `variants`를 nil로 두어 hover tooltip이 수치만 표시.
            let list = variants.map { ModelUsageVariant(model: $0.key, totalTokens: $0.value.tokens, costUSD: $0.value.costUSD) }
            let isTrivial = list.count == 1 && list[0].model == model
            return ModelUsageEntry(model: model, totalTokens: tokens, costUSD: costUSD,
                                   variants: isTrivial ? nil : list)
        }
    }

    static func stripeBalanceCents(from body: [String: Any]?) -> Double {
        guard let body,
              let balance = ProviderParse.number(body["customerBalance"]),
              balance < 0
        else {
            return 0
        }
        return abs(balance)
    }

    private static func appendCredits(creditGrants: [String: Any]?, stripeBalanceCents: Double, to lines: inout [MetricLine]) {
        let hasCreditGrants = creditGrants?["hasCreditGrants"] as? Bool == true
        let grantTotalCents = hasCreditGrants ? ProviderParse.number(creditGrants?["totalCents"]) ?? 0 : 0
        let grantUsedCents = hasCreditGrants ? ProviderParse.number(creditGrants?["usedCents"]) ?? 0 : 0
        let hasValidGrantData = hasCreditGrants && grantTotalCents > 0
        let combinedTotalCents = (hasValidGrantData ? grantTotalCents : 0) + stripeBalanceCents
        let remainingCents = max(0, combinedTotalCents - (hasValidGrantData ? grantUsedCents : 0))

        guard combinedTotalCents > 0 else { return }
        lines.append(.values(
            label: "Credits",
            values: [MetricValue(number: ProviderParse.centsToDollars(remainingCents), kind: .dollars)]
        ))
    }

    private static func billingCycle(from usage: [String: Any]) -> (resetsAt: Date?, periodDurationMs: Int) {
        let cycleStart = ProviderParse.number(usage["billingCycleStart"])
        let cycleEnd = ProviderParse.number(usage["billingCycleEnd"])
        guard let cycleStart,
              let cycleEnd,
              cycleEnd > cycleStart
        else {
            return (cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }, billingPeriodMs)
        }
        return (
            Date(timeIntervalSince1970: cycleEnd / 1000),
            Int(cycleEnd - cycleStart)
        )
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}
