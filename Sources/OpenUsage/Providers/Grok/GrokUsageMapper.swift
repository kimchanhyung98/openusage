import Foundation

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
}

enum GrokUsageMapper {
    /// credits-format billing 응답을 remote line(Weekly meter + pay-as-you-go badge)으로 매핑.
    /// current period가 weekly가 아니면 Weekly 행 생략("No data") — 구 monthly-only 계정의 percent 오표기 방지.
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            lines.append(.progress(
                label: "Weekly limit",
                used: ProviderParse.clampPercent(config.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: config.periodEnd,
                periodDurationMs: config.periodDurationMs
            ))
        }
        // `onDemandCap` 부재는 pay-as-you-go 없음(proto-JSON은 0 cap도 생략) — cap 0과 동일하게 Disabled badge
        lines.append(.badge(
            label: "Pay as you go",
            text: config.onDemandCap > 0 ? "\(formatUnits(config.onDemandCap)) cap" : "Disabled",
            colorHex: config.onDemandCap > 0 ? "#22c55e" : "#a3a3a3"
        ))
        return GrokMappedUsage(lines: lines)
    }

    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let plan = body["subscription_tier_display"] as? String
        else {
            return nil
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func formatUnits(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(value)
    }
}
