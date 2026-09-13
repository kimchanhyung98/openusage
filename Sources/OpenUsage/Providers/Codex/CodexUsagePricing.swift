import Foundation

/// Codex native·Pi 요청의 정규화 토큰에 같은 장문·cache 할인·priority 규칙 적용.
enum CodexUsagePricing {
    static func estimate(model: String, tokens: TokenBreakdown, pricing: ModelPricing) -> Double? {
        let canonical = pricing.supplement.canonicalName(for: model) ?? model
        let isFastAlias = canonical.hasSuffix("-fast")
        let rateModel = isFastAlias ? String(canonical.dropLast("-fast".count)) : canonical
        let baseRates = pricing.resolve(model: rateModel)
        guard let rates = baseRates ?? pricing.resolve(model: model) else { return nil }

        // fast-only catalog는 이미 배율 반영된 단가 — base가 있을 때만 Codex 배율 추가.
        var request = tokens
        request.isFast = isFastAlias ? baseRates != nil : tokens.isFast
        return adjusted(rates: rates, model: rateModel).costDollars(for: request)
    }

    static func estimatePi(model: String, tokens: TokenBreakdown, pricing: ModelPricing) -> PiUsageScanner.CostEstimate {
        guard tokens.cacheWrite1h == 0 else {
            AppLog.warn(LogTag.plugin("codex"), "Codex pricing: unsupported one-hour cache-write usage")
            return .unsupportedUsage
        }
        return .init(estimate(model: model, tokens: tokens, pricing: pricing))
    }

    static func adjusted(rates: ModelRates, model: String) -> ModelRates {
        var effective = rates
        let base = datedBaseModel(model)
        switch base {
        case "gpt-5.4", "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro",
             "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra":
            effective.inputAbove200kPerMillion = rates.inputPerMillion * 2
            effective.outputAbove200kPerMillion = rates.outputPerMillion * 1.5
            effective.cacheWriteAbove200kPerMillion = rates.cacheWritePerMillion * 2
            effective.cacheReadAbove200kPerMillion = rates.cacheReadPerMillion * 2
            effective.longContextThresholdTokens = 272_000
        default:
            break
        }
        if base == "gpt-5.4-pro" || base == "gpt-5.5-pro" || !rates.cacheReadIsExplicit {
            effective.cacheReadPerMillion = effective.inputPerMillion
            effective.cacheReadAbove200kPerMillion = effective.inputAbove200kPerMillion
        }
        switch base {
        case "gpt-5.5", "gpt-5.5-pro":
            effective.fastMultiplier = 2.5
        case "gpt-5.4", "gpt-5.4-pro", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra":
            effective.fastMultiplier = 2
        default:
            effective.fastMultiplier = rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
        return effective
    }

    private static func datedBaseModel(_ model: String) -> String {
        model
            .replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
