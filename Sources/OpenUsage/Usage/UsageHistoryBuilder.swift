import Foundation

enum UsageHistoryBuilder {
    enum CostEstimate: Sendable {
        case priced(Double)
        case unpriced
        case unsupportedUsage

        init(_ cost: Double?) {
            self = cost.map(Self.priced) ?? .unpriced
        }
    }

    typealias CostEstimator = @Sendable (UsageRecord, ModelPricing) -> CostEstimate

    /// 미귀속 프로바이더 기록은 원본 수집 결과에 보존하고 해당 카드의 집계에서만 제외.
    static func scan(
        _ collection: UsageCollection, providerID: String, since: Date, until: Date = .distantFuture,
        pricing: ModelPricing,
        costEstimator: CostEstimator? = nil, allowEstimates: Bool = true
    ) -> LogUsageScan? {
        let sharedSources: Set<String> = ["pi", "omp", "openclaw", "hermes", "dsh"]
        let records = collection.records.filter {
            $0.scope == .machineLocal && (UsageProviderMapping.providerID(for: $0.providerID) == providerID
                || ($0.providerID == nil && sharedSources.contains($0.sourceID) && $0.issues.contains(.invalidMetadata)))
        }
        let sources = collection.sources.filter {
            $0.scope == .machineLocal && ($0.providerID == nil || $0.providerID == providerID)
        }
        let readFailures = sources.reduce(0) { $0 + $1.failedStores }
        guard !records.isEmpty || readFailures > 0 || sources.contains(where: { $0.completedStores > 0 }) else { return nil }
        let estimate: CostEstimator = costEstimator ?? { record, pricing in
            if providerID == "codex" { return CodexUsagePricing.estimateRecord(record, pricing: pricing) }
            guard let tokens = record.tokens, let model = record.effectiveModel else { return .unpriced }
            if record.sourceID == "omp", record.providerID == "anthropic", record.serviceTier == "priority",
               let rates = pricing.resolve(model: model) {
                let multiplier = rates.fastMultiplier > 1 ? rates.fastMultiplier : pricing.supplement.exactFastMultiplier(for: model)
                if let multiplier, multiplier > 1 {
                    return CostEstimate(rates.scaled(by: multiplier).costDollars(
                        for: tokens, applyLongContextRates: record.granularity == .request
                    ))
                }
            }
            return CostEstimate(pricing.estimatedCostDollars(
                model: model, tokens: tokens, applyLongContextRates: record.granularity == .request
            ))
        }
        var accumulator = DailyUsageAccumulator()
        var rejectedNumbers = 0
        var rejectedMetadata = 0
        var unsupportedPricing = 0
        for record in records {
            guard record.overlaps(since: since) else { continue }
            if let timestamp = record.timestamp, timestamp > until { continue }
            guard !record.issues.contains(.invalidMetadata), !record.issues.contains(.unresolvedMirror),
                  let timestamp = record.timestamp else {
                rejectedMetadata += 1
                continue
            }
            guard !record.issues.contains(.invalidNumbers) else {
                rejectedNumbers += 1
                continue
            }
            var pricingIncomplete = record.issues.contains(.unsupportedPricing)
            let cost: Double?
            if let recorded = record.recordedCostUSD, recorded > 0 || !record.zeroCostIsUnknown,
               allowEstimates || record.costOrigin == .reported {
                cost = recorded
            } else if !allowEstimates || pricingIncomplete {
                cost = nil
            } else {
                switch estimate(record, pricing) {
                case .priced(let value): cost = value
                case .unpriced: cost = nil
                case .unsupportedUsage:
                    cost = nil
                    pricingIncomplete = true
                }
            }
            if pricingIncomplete, cost == nil, record.totalTokens > 0 { unsupportedPricing += 1 }
            let day = DailyUsageAccumulator.dayKey(from: timestamp)
            let model = record.effectiveModel ?? ModelUsageEntry.unattributedModelName
            accumulator.add(day: day, tokens: record.totalTokens, cost: cost, model: model)
            if cost == nil, record.totalTokens > 0 { accumulator.addUnknownModel(day: day, model: model) }
        }
        if unsupportedPricing > 0 {
            AppDiagnostics.record(.historyScan, result: .degraded, category: .other, providerID: providerID,
                                  localContext: "unsupported_pricing_rows=\(unsupportedPricing)")
        }
        return accumulator.build(
            rejectedNumericRows: rejectedNumbers, source: providerID, unsupportedPricingRows: unsupportedPricing,
            rejectedMetadataRows: rejectedMetadata, readFailureCount: readFailures
        )
    }
}

enum UsageProviderMapping {
    private static let providers: [String: String] = [
        "anthropic": "claude",
        "claude-agent-sdk": "claude",
        "openai-codex": "codex",
        "cursor": "cursor",
        "zai": "zai",
        "zhipu": "zai",
        "google-antigravity": "antigravity",
        "github-copilot": "copilot",
        "claude": "claude", "codex": "codex", "grok": "grok", "devin": "devin",
        "kimi": "kimi", "kiro": "kiro", "opencode": "opencode", "opencode-go": "opencode", "openrouter": "openrouter",
        "antigravity": "antigravity", "copilot": "copilot"
    ]

    static func providerID(for recordedProvider: String?) -> String? {
        recordedProvider.flatMap { providers[$0] }
    }
}
