import Foundation

/// OpenRouter `/credits`·`/key` payload에서 metric line 생성.
/// endpoint별 독립 매핑 — 한쪽이 실패해도 다른 쪽의 행은 그대로 사용 가능.
enum OpenRouterUsageMapper {
    /// 모든 payload는 `{ "data": { ... } }` 형태로 감싸져 옴.
    static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    /// `/credits`에서 Credits meter + Balance 생성 — 유효한 total이 없으면 빈 배열.
    static func creditsLines(from data: [String: Any]) -> [MetricLine] {
        guard let totalUsage = ProviderParse.number(data["total_usage"]),
              let totalCredits = ProviderParse.number(data["total_credits"]) else { return [] }
        let balance = totalCredits - totalUsage
        guard balance.isFinite else { return [] }

        var lines: [MetricLine] = []
        // Credits meter는 양수 상한일 때만 의미 있음(무충전 계정은 0 보고) — 해당 계정도 Balance는 표시
        if totalCredits > 0 {
            lines.append(.progress(label: "Credits", used: totalUsage, limit: totalCredits, format: .dollars))
        }
        // 실측 0과 초과 사용에 따른 음수 잔액 모두 유지.
        lines.append(.values(
            label: "Balance",
            values: [MetricValue(number: balance, kind: .dollars)]
        ))
        return lines
    }

    /// `/key`에서 period spend + per-key cap(선택) 생성, tier는 plan 이름으로 노출.
    static func keyMetrics(
        from data: [String: Any], includePeriodUsage: Bool = true
    ) -> (plan: String?, lines: [MetricLine], hasInvalidKeyLimit: Bool) {
        var lines: [MetricLine] = []
        var hasInvalidKeyLimit = false

        // period spend는 로컬 로그 scan이 아닌 API 직접 값 — 실측 0은 측정된 0으로 유지
        if includePeriodUsage {
            appendSpend(data["usage_daily"], label: "Today", into: &lines)
            appendSpend(data["usage_weekly"], label: "This Week", into: &lines)
            appendSpend(data["usage_monthly"], label: "This Month", into: &lines)
        }

        if let limit = ProviderParse.number(data["limit"]), limit > 0 {
            // `usage`는 전체 기간 누적액 — 현재 한도 창의 잔여액으로만 사용량 계산.
            if let remaining = ProviderParse.number(data["limit_remaining"]) {
                lines.append(.progress(
                    label: "Key Limit",
                    used: max(0, limit - max(0, remaining)),
                    limit: limit,
                    format: .dollars
                ))
            } else {
                hasInvalidKeyLimit = true
            }
        }

        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free tier" : "Pay as you go" }
        return (plan, lines, hasInvalidKeyLimit)
    }

    private static func appendSpend(_ value: Any?, label: String, into lines: inout [MetricLine]) {
        guard let amount = ProviderParse.number(value) else { return }
        lines.append(.values(label: label, values: [MetricValue(number: max(0, amount), kind: .dollars)]))
    }
}
