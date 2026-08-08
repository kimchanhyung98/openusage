import Foundation

/// Cursor Enterprise/team dashboard가 쓰는 두 REST payload 결합. request endpoint는 포함 request allowance, usage-summary는 구조화 percentage·user 단위 on-demand spend·정확한 billing-cycle 경계 — 어느 한쪽만으로는 불충분.
enum CursorUsageSummaryMapper {
    static func hasUsableSummaryPayload(_ summary: [String: Any]) -> Bool {
        let start = (summary["billingCycleStart"] as? String).flatMap(OpenUsageISO8601.date(from:))
        let end = (summary["billingCycleEnd"] as? String).flatMap(OpenUsageISO8601.date(from:))
        if let start, let end, end > start {
            return true
        }

        let individual = summary["individualUsage"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        if ["totalPercentUsed", "autoPercentUsed", "apiPercentUsed"].contains(where: {
            ProviderParse.number(plan?[$0]) != nil
        }) {
            return true
        }
        return [individual?["onDemand"], individual?["overall"], team?["onDemand"], team?["pooled"]]
            .contains(where: usableDollarBucket)
    }

    static func hasUsableRequestPayload(_ usage: [String: Any]) -> Bool {
        if let requests = usage["gpt-4"] as? [String: Any],
           let limit = ProviderParse.number(requests["maxRequestUsage"]), limit > 0 {
            return true
        }
        return (usage["startOfMonth"] as? String).flatMap(OpenUsageISO8601.date(from:)) != nil
    }

    static func map(
        summary: [String: Any]?,
        requestUsage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        let cycle = billingCycle(summary: summary, requestUsage: requestUsage)
        var lines: [MetricLine] = []

        let hasRequests = appendRequests(requestUsage, cycle: cycle, to: &lines)
        if !hasRequests {
            appendSummaryTotal(summary, cycle: cycle, to: &lines)
        }
        appendStructuredPercentages(summary, cycle: cycle, to: &lines)
        appendOnDemand(summary, cycle: cycle, to: &lines)

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(
            plan: planLabel(planName) ?? planLabel(summary?["membershipType"] as? String),
            lines: lines
        )
    }

    /// request 기반 Enterprise plan에서 기본 Total Usage 위젯이 포함 allowance를 실어야 함. legacy Requests line도 유지 — 그 optional 위젯을 수동으로 켠 사용자가 업그레이드 후 잃지 않도록.
    private static func appendRequests(
        _ usage: [String: Any]?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) -> Bool {
        guard let requests = usage?["gpt-4"] as? [String: Any],
              let limit = ProviderParse.number(requests["maxRequestUsage"]),
              limit > 0
        else {
            return false
        }
        let used = max(
            0,
            ProviderParse.number(requests["numRequests"])
                ?? ProviderParse.number(requests["numRequestsTotal"])
                ?? 0
        )
        for label in ["Total usage", "Requests"] {
            lines.append(.progress(
                label: label,
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }
        return true
    }

    /// live `individualUsage.plan` 형태와 다른 Enterprise 계정의 pooled/overall variant 모두 지원. request allowance가 우선 — dashboard의 포함 cap이기 때문.
    private static func appendSummaryTotal(
        _ summary: [String: Any]?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        let limitType = (summary?["limitType"] as? String)?.lowercased()

        if limitType == "team", let pooled = dollarMeter(team?["pooled"]) {
            appendDollarProgress(pooled, label: "Total usage", cycle: cycle, to: &lines)
            return
        }
        if let percent = ProviderParse.number((individual?["plan"] as? [String: Any])?["totalPercentUsed"]) {
            lines.append(.progress(
                label: "Total usage",
                used: percent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
            return
        }
        if let overall = dollarMeter(individual?["overall"]) {
            appendDollarProgress(overall, label: "Total usage", cycle: cycle, to: &lines)
            return
        }
        if let pooled = dollarMeter(team?["pooled"]) {
            appendDollarProgress(pooled, label: "Total usage", cycle: cycle, to: &lines)
        }
    }

    private static func appendStructuredPercentages(
        _ summary: [String: Any]?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let plan = ((summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])
        for (key, label) in [("autoPercentUsed", "Auto usage"), ("apiPercentUsed", "API usage")] {
            guard let percent = ProviderParse.number(plan?[key]) else { continue }
            lines.append(.progress(
                label: label,
                used: percent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }
    }

    /// dashboard의 대표 On-Demand 카드는 user 단위. organization 집계는 Cursor가 그 계정 형태에서 individual bucket을 생략할 때만 사용.
    private static func appendOnDemand(
        _ summary: [String: Any]?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        if appendOnDemandBucket(individual?["onDemand"], cycle: cycle, to: &lines) {
            return
        }
        _ = appendOnDemandBucket(team?["onDemand"], cycle: cycle, to: &lines)
    }

    /// 쓸 만한 행을 냈는지 반환. Enterprise 응답은 유효한 team bucket 옆에 individual placeholder bucket(`enabled: false` 또는 0 limit)을 실을 수 있음 — individual dictionary 발견만으로 fallback을 억제하면 안 됨.
    private static func appendOnDemandBucket(
        _ value: Any?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) -> Bool {
        guard let bucket = value as? [String: Any], bucket["enabled"] as? Bool != false else {
            return false
        }
        if let meter = dollarMeter(bucket) {
            appendDollarProgress(meter, label: "On-demand", cycle: cycle, to: &lines)
            return true
        }
        if let usedCents = ProviderParse.number(bucket["used"]), usedCents > 0 {
            lines.append(.values(
                label: "On-demand",
                values: [MetricValue(number: ProviderParse.centsToDollars(usedCents), kind: .dollars)]
            ))
            return true
        }
        return false
    }

    private static func dollarMeter(_ value: Any?) -> (used: Double, limit: Double)? {
        guard let bucket = value as? [String: Any],
              bucket["enabled"] as? Bool != false,
              let limit = ProviderParse.number(bucket["limit"]),
              limit > 0
        else {
            return nil
        }
        let reportedUsed = ProviderParse.number(bucket["used"])
        let inferredUsed = max(0, limit - (ProviderParse.number(bucket["remaining"]) ?? limit))
        let used = reportedUsed.flatMap { $0 > 0 ? $0 : nil } ?? inferredUsed
        return (max(0, used), limit)
    }

    private static func usableDollarBucket(_ value: Any?) -> Bool {
        guard let bucket = value as? [String: Any], bucket["enabled"] as? Bool != false else {
            return false
        }
        return dollarMeter(bucket) != nil || (ProviderParse.number(bucket["used"]) ?? 0) > 0
    }

    private static func appendDollarProgress(
        _ meter: (used: Double, limit: Double),
        label: String,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) {
        lines.append(.progress(
            label: label,
            used: ProviderParse.centsToDollars(meter.used),
            limit: ProviderParse.centsToDollars(meter.limit),
            format: .dollars,
            resetsAt: cycle.resetsAt,
            periodDurationMs: cycle.periodDurationMs
        ))
    }

    private static func billingCycle(
        summary: [String: Any]?,
        requestUsage: [String: Any]?
    ) -> BillingCycle {
        let start = (summary?["billingCycleStart"] as? String).flatMap(OpenUsageISO8601.date(from:))
        let end = (summary?["billingCycleEnd"] as? String).flatMap(OpenUsageISO8601.date(from:))
        if let start, let end, end > start {
            return BillingCycle(
                resetsAt: end,
                periodDurationMs: Int(end.timeIntervalSince(start) * 1000)
            )
        }

        let requestStart = (requestUsage?["startOfMonth"] as? String).flatMap(OpenUsageISO8601.date(from:))
        return BillingCycle(
            resetsAt: requestStart?.addingTimeInterval(TimeInterval(CursorUsageMapper.billingPeriodMs) / 1000),
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.titleCased(separator: \.isWhitespace)
    }

    private struct BillingCycle {
        var resetsAt: Date?
        var periodDurationMs: Int
    }
}
