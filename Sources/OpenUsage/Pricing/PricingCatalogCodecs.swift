import Foundation

/// 공개 pricing feed 2종의 parser + bundled snapshot·disk cache용 compact catalog format.
/// compact format은 cost field만 보존 — 원본 feed는 수 MB.
enum PricingCatalogCodecs {
    // MARK: - LiteLLM (model_prices_and_context_window.json)

    /// LiteLLM 전체 JSON에서 catalog 생성 — input·output cost 없는 entry 제외, feed의 per-token을 per-million으로 저장.
    /// JSONSerialization 사용 — 불량 entry 하나가 feed 전체를 무너뜨리지 않는 계약.
    static func catalogFromLiteLLM(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                  let input = doubleValue(entry["input_cost_per_token"]),
                  let output = doubleValue(entry["output_cost_per_token"]) else { continue }
            let cacheWrite = doubleValue(entry["cache_creation_input_token_cost"])
            let cacheRead = doubleValue(entry["cache_read_input_token_cost"])
            var rates = ModelRates(
                inputPerMillion: input * 1_000_000,
                outputPerMillion: output * 1_000_000,
                cacheWritePerMillion: (cacheWrite ?? input) * 1_000_000,
                cacheReadPerMillion: (cacheRead ?? input * 0.1) * 1_000_000,
                cacheReadIsExplicit: cacheRead != nil
            )
            rates.inputAbove200kPerMillion = doubleValue(entry["input_cost_per_token_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.outputAbove200kPerMillion = doubleValue(entry["output_cost_per_token_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.cacheWriteAbove200kPerMillion = doubleValue(entry["cache_creation_input_token_cost_above_200k_tokens"]).map { $0 * 1_000_000 }
            rates.cacheReadAbove200kPerMillion = doubleValue(entry["cache_read_input_token_cost_above_200k_tokens"]).map { $0 * 1_000_000 }
            if let providerSpecific = entry["provider_specific_entry"] as? [String: Any],
               let fast = doubleValue(providerSpecific["fast"]) {
                rates.fastMultiplier = fast
            }
            entries[key] = rates
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    // MARK: - models.dev (api.json)

    /// models.dev `api.json`(`{provider: {models: {id: {cost: ...}}}}`)에서 catalog 생성.
    /// model id는 bare 저장 — 동일 id 중복 시 provider명 정렬 첫 항목 승리, cost는 feed에서 이미 per-million.
    static func catalogFromModelsDev(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for providerName in root.keys.sorted() {
            guard let provider = root[providerName] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, value) in models {
                guard entries[modelID] == nil,
                      let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = doubleValue(cost["input"]),
                      let output = doubleValue(cost["output"]) else { continue }
                entries[modelID] = ModelRates(
                    inputPerMillion: input,
                    outputPerMillion: output,
                    cacheWritePerMillion: doubleValue(cost["cache_write"]) ?? input,
                    cacheReadPerMillion: doubleValue(cost["cache_read"]) ?? input * 0.1,
                    cacheReadIsExplicit: cost["cache_read"] != nil
                )
            }
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    // MARK: - Compact format (bundled snapshots + disk cache)

    static func catalogFromCompact(_ data: Data) throws -> PricingCatalog {
        let file = try JSONDecoder().decode(CompactCatalog.self, from: data)
        var entries: [String: ModelRates] = [:]
        entries.reserveCapacity(file.models.count)
        for (key, model) in file.models {
            entries[key] = ModelRates(
                inputPerMillion: model.i,
                outputPerMillion: model.o,
                cacheWritePerMillion: model.cw,
                cacheReadPerMillion: model.cr,
                inputAbove200kPerMillion: model.ia,
                outputAbove200kPerMillion: model.oa,
                cacheWriteAbove200kPerMillion: model.cwa,
                cacheReadAbove200kPerMillion: model.cra,
                cacheReadIsExplicit: model.cre ?? true,
                fastMultiplier: model.fast ?? 1
            )
        }
        return PricingCatalog(entries: entries, retrievedAt: file.retrievedAt)
    }

    static func compactData(from catalog: PricingCatalog) throws -> Data {
        var models: [String: CompactCatalog.Model] = [:]
        models.reserveCapacity(catalog.entries.count)
        for (key, rates) in catalog.entries {
            models[key] = CompactCatalog.Model(
                i: rates.inputPerMillion,
                o: rates.outputPerMillion,
                cw: rates.cacheWritePerMillion,
                cr: rates.cacheReadPerMillion,
                ia: rates.inputAbove200kPerMillion,
                oa: rates.outputAbove200kPerMillion,
                cwa: rates.cacheWriteAbove200kPerMillion,
                cra: rates.cacheReadAbove200kPerMillion,
                cre: rates.cacheReadIsExplicit ? nil : false,
                fast: rates.fastMultiplier == 1 ? nil : rates.fastMultiplier
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CompactCatalog(retrievedAt: catalog.retrievedAt, models: models))
    }

    /// snapshot 축소용 단축 key의 per-million rates — `i`nput, `o`utput, `c`ache`w`rite, `c`ache`r`ead, `a`bove-200k 변형, `fast` multiplier.
    private struct CompactCatalog: Codable {
        var retrievedAt: String?
        var models: [String: Model]

        struct Model: Codable {
            var i: Double
            var o: Double
            var cw: Double
            var cr: Double
            var ia: Double?
            var oa: Double?
            var cwa: Double?
            var cra: Double?
            /// 생략 = explicit — provenance bit 이전 snapshot과의 하위 호환. 새로 compact되는 합성 rate는 `false` 기록.
            var cre: Bool?
            var fast: Double?
        }

        enum CodingKeys: String, CodingKey {
            case retrievedAt = "retrieved_at"
            case models
        }
    }
}

enum PricingCodecError: Error, LocalizedError, Equatable {
    case notAnObject
    case noUsableEntries

    var errorDescription: String? {
        switch self {
        case .notAnObject: return "Pricing feed is not a JSON object."
        case .noUsableEntries: return "Pricing feed contained no usable model entries."
        }
    }
}
