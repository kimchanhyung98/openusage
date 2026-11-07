import Foundation

/// model 1개의 per-million-token USD rates + 선택적 long-context tier·fast-variant multiplier.
/// 모든 spend imputation (Claude, Codex, Cursor, Grok)의 공용 가격 기준.
struct ModelRates: Sendable, Equatable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    /// 5분 ephemeral cache write (Anthropic식) — 별도 cache-write 가격 없는 provider는 input rate와 동일.
    var cacheWritePerMillion: Double
    var cacheReadPerMillion: Double

    /// prompt가 long-context threshold를 넘는 request의 rates — request 전체를 상위 tier로 과금.
    /// field명은 catalog 관례 `above_200k` 유지, 실제 경계는 `longContextThresholdTokens`가 결정.
    var inputAbove200kPerMillion: Double?
    var outputAbove200kPerMillion: Double?
    var cacheWriteAbove200kPerMillion: Double?
    var cacheReadAbove200kPerMillion: Double?

    /// pricing source의 cache-read rate 명시 발행 여부.
    /// codec은 일반 추정용으로 input 10% fallback을 합성 — Codex는 discount 미발행 시 full input 과금 필수.
    var cacheReadIsExplicit: Bool = true

    /// 선택적 long-context rates가 적용되는 prompt-token threshold.
    var longContextThresholdTokens: Int = 200_000

    /// "fast" variant의 rate multiplier (variant 없으면 1).
    var fastMultiplier: Double = 1

    /// 모든 dollar 수치에 배율 적용한 동일 rates — `-fast` slug를 base entry로 가격 산정할 때 사용.
    func scaled(by factor: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: inputPerMillion * factor,
            outputPerMillion: outputPerMillion * factor,
            cacheWritePerMillion: cacheWritePerMillion * factor,
            cacheReadPerMillion: cacheReadPerMillion * factor,
            inputAbove200kPerMillion: inputAbove200kPerMillion.map { $0 * factor },
            outputAbove200kPerMillion: outputAbove200kPerMillion.map { $0 * factor },
            cacheWriteAbove200kPerMillion: cacheWriteAbove200kPerMillion.map { $0 * factor },
            cacheReadAbove200kPerMillion: cacheReadAbove200kPerMillion.map { $0 * factor },
            cacheReadIsExplicit: cacheReadIsExplicit,
            longContextThresholdTokens: longContextThresholdTokens,
            fastMultiplier: 1
        )
    }
}

/// 가격이 다르게 매겨지는 bucket별 token count — 모든 scanner의 정규화 대상.
struct TokenBreakdown: Codable, Sendable, Equatable {
    /// cache 미사용 일반 input rate 과금 token.
    var input: Int = 0
    /// 5분 ephemeral cache에 기록된 input token.
    var cacheWrite5m: Int = 0
    /// 1시간 ephemeral cache에 기록된 input token — input 2배 과금.
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0
    var output: Int = 0
    /// request가 "fast" variant로 실행됨 (Claude log의 `speed` field).
    var isFast: Bool = false

    /// long-context threshold 판정 대상 input — output은 tier 선택에 미관여하나 선택된 tier로 과금.
    var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

extension ModelRates {
    /// 1시간 cache write는 input rate 2배 과금 (ccusage 규칙 — LiteLLM 명시 `above_1hr` field와 일치).
    private static let cacheWrite1hInputMultiplier = 2.0

    /// 이 rates 기준 request 1건의 dollar cost — request 전체 long-context tier와 fast multiplier 적용.
    /// request 경계를 보존하지 않는 집계 source는 long-context 적용 opt-out 가능.
    func costDollars(for tokens: TokenBreakdown, applyLongContextRates: Bool = true) -> Double {
        let multiplier = tokens.isFast ? fastMultiplier : 1
        let useLongContextRates = applyLongContextRates && tokens.promptTokens > longContextThresholdTokens
        let inputRate = selectedRate(base: inputPerMillion, longContext: inputAbove200kPerMillion,
                                     useLongContextRates: useLongContextRates)
        let outputRate = selectedRate(base: outputPerMillion, longContext: outputAbove200kPerMillion,
                                      useLongContextRates: useLongContextRates)
        let cacheWriteRate = selectedRate(base: cacheWritePerMillion, longContext: cacheWriteAbove200kPerMillion,
                                          useLongContextRates: useLongContextRates)
        let cacheReadRate = selectedRate(base: cacheReadPerMillion, longContext: cacheReadAbove200kPerMillion,
                                         useLongContextRates: useLongContextRates)
        let cacheWrite1hRate = selectedRate(
            base: inputPerMillion,
            longContext: inputAbove200kPerMillion,
            useLongContextRates: useLongContextRates
        ) * Self.cacheWrite1hInputMultiplier

        let cost = cost(tokens.input, at: inputRate)
            + cost(tokens.output, at: outputRate)
            + cost(tokens.cacheWrite5m, at: cacheWriteRate)
            + cost(tokens.cacheWrite1h, at: cacheWrite1hRate)
            + cost(tokens.cacheRead, at: cacheReadRate)
        return cost * multiplier
    }

    private func selectedRate(base: Double, longContext: Double?, useLongContextRates: Bool) -> Double {
        useLongContextRates ? (longContext ?? base) : base
    }

    private func cost(_ tokens: Int, at ratePerMillion: Double) -> Double {
        Double(tokens) * ratePerMillion / 1_000_000
    }
}
