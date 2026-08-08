import Foundation

/// OpenUsage 자체 pricing feed — 공개 catalog에 없는 model, catalog이 생략한 fast multiplier, log/CSV slug → canonical key alias 규칙.
/// `pricing_supplement.json`으로 bundled, gh-pages에서 refresh — 앱 release 없이 entry 갱신.
struct PricingSupplement: Sendable {
    /// supplement가 직접 가격 매기는 model — 최우선 source.
    let pricing: [String: ModelRates]
    /// fast variant·request 수준 fast 신호용 base-model multiplier.
    let fastMultipliers: [String: Double]
    let aliasRules: [AliasRule]
    let updatedAt: String?

    /// regex slug → canonical pricing key. 규칙 순서 적용 — 첫 일치 승리.
    struct AliasRule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let canonical: String
    }

    init(
        pricing: [String: ModelRates] = [:],
        fastMultipliers: [String: Double] = [:],
        aliasRules: [AliasRule] = [],
        updatedAt: String? = nil
    ) {
        self.pricing = pricing
        self.fastMultipliers = fastMultipliers
        self.aliasRules = aliasRules
        self.updatedAt = updatedAt
    }

    /// alias 규칙 기준 `model`의 canonical pricing key — 일치 규칙 없으면 nil.
    func canonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..., in: model)
        for rule in aliasRules where rule.pattern.firstMatch(in: model, range: range) != nil {
            return rule.canonical
        }
        return nil
    }

    /// resolve된 base model의 fast multiplier — 정확 key 우선, 다음 ccusage식 정규화 suffix 매칭으로 dated key도 base entry 탐색.
    func fastMultiplier(for model: String) -> Double? {
        if let exact = fastMultipliers[model] { return exact }
        let normalized = PricingCatalog.normalizedKey(model)
        for part in normalized.split(whereSeparator: { $0 == "/" || $0 == ":" }) {
            for (base, multiplier) in fastMultipliers {
                if Self.matchesModelSuffix(part: String(part), base: PricingCatalog.normalizedKey(base)) {
                    return multiplier
                }
            }
        }
        return nil
    }

    /// `part` 안 `base` 뒤가 비어 있거나 `-` separator로 이어지는 경우만 일치.
    private static func matchesModelSuffix(part: String, base: String) -> Bool {
        guard let range = part.range(of: base, options: .backwards) else { return false }
        let suffix = part[range.upperBound...]
        return suffix.isEmpty || suffix.hasPrefix("-")
    }
}

// MARK: - JSON decoding

extension PricingSupplement {
    /// supplement JSON decode (bundled resource 또는 gh-pages feed) — 불량 JSON은 throw, 개별 불량 alias pattern은 log 후 skip.
    static func decode(from data: Data) throws -> PricingSupplement {
        let file = try JSONDecoder().decode(SupplementFile.self, from: data)
        var pricing: [String: ModelRates] = [:]
        for (model, entry) in file.pricing {
            pricing[model] = ModelRates(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion ?? entry.inputPerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion ?? entry.inputPerMillion * 0.1,
                cacheReadIsExplicit: entry.cacheReadPerMillion != nil,
                // Claude `speed` field 같은 request 수준 fast 신호 보존.
                fastMultiplier: file.fastMultipliers?[model] ?? 1
            )
        }
        var rules: [AliasRule] = []
        for rule in file.aliasRules {
            do {
                let pattern = try NSRegularExpression(pattern: rule.pattern)
                rules.append(AliasRule(pattern: pattern, canonical: rule.canonical))
            } catch {
                AppLog.warn(.cache, "pricing supplement: invalid alias pattern '\(rule.pattern)' skipped: \(error.localizedDescription)")
            }
        }
        return PricingSupplement(
            pricing: pricing,
            fastMultipliers: file.fastMultipliers ?? [:],
            aliasRules: rules,
            updatedAt: file.updatedAt
        )
    }

    private struct SupplementFile: Decodable {
        var updatedAt: String?
        var pricing: [String: Entry]
        var fastMultipliers: [String: Double]?
        var aliasRules: [Rule]

        struct Entry: Decodable {
            var inputPerMillion: Double
            var outputPerMillion: Double
            var cacheWritePerMillion: Double?
            var cacheReadPerMillion: Double?

            enum CodingKeys: String, CodingKey {
                case inputPerMillion = "input_per_million"
                case outputPerMillion = "output_per_million"
                case cacheWritePerMillion = "cache_write_per_million"
                case cacheReadPerMillion = "cache_read_per_million"
            }
        }

        struct Rule: Decodable {
            var pattern: String
            var canonical: String
        }

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case pricing
            case fastMultipliers = "fast_multipliers"
            case aliasRules = "alias_rules"
        }
    }
}
