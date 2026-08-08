import Foundation
import os

/// 불변 pricing snapshot — supplement + 공개 catalog 2종. `ModelPricingStore`가 생성, scanner/mapper가 한 parse pass 동안 동기 사용.
/// 해석 순서: supplement alias 재작성 → supplement 정확 일치 → LiteLLM 정확 → `-fast`는 base × fast multiplier(배율 없으면 미가격)
/// → LiteLLM fuzzy(비-fast slug만) → models.dev 정확 일치만 — reseller 집계 특성상 fuzzy는 오가격 위험, unknown variant는 미가격 유지.
final class ModelPricing: Sendable {
    let supplement: PricingSupplement
    /// LiteLLM `model_prices_and_context_window.json` — bundled snapshot에 fetch 데이터 merge.
    let primary: PricingCatalog
    /// models.dev `api.json` — LiteLLM 누락 model의 gap-filler.
    let secondary: PricingCatalog

    /// fuzzy miss마다 전체 catalog 순회 — model 이름별 memoize. snapshot 불변이라 entry invalidation 없음.
    private let memo = OSAllocatedUnfairLock<[String: ModelRates?]>(initialState: [:])

    init(supplement: PricingSupplement, primary: PricingCatalog, secondary: PricingCatalog) {
        self.supplement = supplement
        self.primary = primary
        self.secondary = secondary
    }

    static let empty = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog())

    /// `model`의 rates — 어떤 source도 가격 못 매기면 nil (caller가 unknown-model 경고 표시, token은 $0 계산).
    func resolve(model: String) -> ModelRates? {
        if let cached = memo.withLock({ $0[model] }) {
            return cached
        }
        let resolved = resolveUncached(model: model)
        memo.withLock { $0[model] = resolved }
        return resolved
    }

    /// `model` 기준 `tokens`의 dollar cost — 미가격 model이면 nil.
    /// request 경계를 보존하지 않는 집계 source는 long-context tier 비활성 가능.
    func estimatedCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true
    ) -> Double? {
        guard let rates = resolve(model: model) else { return nil }
        return rates.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }

    private func resolveUncached(model: String) -> ModelRates? {
        if let canonical = supplement.canonicalName(for: model), canonical != model {
            return lookup(canonical) ?? lookup(model)
        }
        return lookup(model)
    }

    /// secondary catalog은 primary 전체 miss 후에만 조회 (ccusage 방식) — LiteLLM이 알면 항상 우선, models.dev는 정확 id만 응답.
    private func lookup(_ name: String) -> ModelRates? {
        if let entry = supplement.pricing[name] { return entry }
        if let exact = primary.findExact(name) { return exact.rates }
        if let fast = fastVariant(name) { return fast }
        if name.hasSuffix("-fast") { return secondary.findExact(name)?.rates }
        if let fuzzy = primary.findFuzzy(name) { return fuzzy.rates }
        if let exact = secondary.findExact(name) { return exact.rates }
        return nil
    }

    /// `<base>-fast` slug를 base entry × fast multiplier로 가격 산정 — multiplier 미상이면 nil.
    /// caller는 models.dev의 정확 fast entry는 수용 가능하나 표준 속도 base rate로의 fuzzy 매칭은 금지.
    private func fastVariant(_ name: String) -> ModelRates? {
        guard name.hasSuffix("-fast") else { return nil }
        let base = String(name.dropLast("-fast".count))
        guard !base.isEmpty else { return nil }
        guard let (key, rates) = baseEntry(base) else { return nil }
        let multiplier: Double
        if rates.fastMultiplier != 1 {
            multiplier = rates.fastMultiplier
        } else if let supplementMultiplier = supplement.fastMultiplier(for: key) ?? supplement.fastMultiplier(for: base) {
            multiplier = supplementMultiplier
        } else {
            return nil
        }
        return rates.scaled(by: multiplier)
    }

    private func baseEntry(_ base: String) -> (key: String, rates: ModelRates)? {
        if let entry = supplement.pricing[base] { return (base, entry) }
        return primary.findExact(base)
            ?? primary.findFuzzy(base)
            ?? secondary.findExact(base)
    }
}
