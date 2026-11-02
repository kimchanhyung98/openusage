import Foundation

struct ZAIDetailWindow: Sendable {
    let days: [String]
    let hourly: Bool
    let hourlyThrough: Int?

    init(days: [String], hourly: Bool, hourlyThrough: Int? = nil) {
        self.days = days
        self.hourly = hourly
        self.hourlyThrough = hourlyThrough
    }

    var startTime: String { days.first! + " 00:00:00" }
    var endTime: String { days.last! + " 23:59:59" }
}

/// 같은 모델별 토큰 분해에서 비용과 분모를 함께 계산. 불완전한 날은 비용 미확정으로 유지.
enum ZAIDetailMapper {
    struct Day: Sendable {
        var tokens: Int = 0
        var tokensComplete: Bool
        var costUSD: Double? = 0
    }

    struct Parsed: Sendable {
        let days: [String: Day]
    }

    static func map(_ body: Data, window: ZAIDetailWindow, pricing: ModelPricing) throws -> Parsed {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: body),
              envelope.success != false, envelope.code == nil || envelope.code == 0 || envelope.code == 200,
              let usage = envelope.data?.modelUsage else { throw ZAIUsageError.invalidResponse }

        if usage.xTime.isEmpty, usage.modelDataList.isEmpty { return Parsed(days: [:]) }
        let axis = try validatedAxis(usage.xTime, window: window)
        let axisDays = axis.days
        let coveredDays = Set(axisDays)
        var days = Dictionary(uniqueKeysWithValues: window.days.map { day in
            let complete = coveredDays.contains(day) && axis.completeHourly
            return (day, Day(tokensComplete: complete, costUSD: complete ? 0 : nil))
        })
        var seenModels = Set<String>()
        var seenBuckets = Set<String>()
        for model in usage.modelDataList {
            if let bucket = aggregateBucket(model) {
                guard seenBuckets.insert(bucket).inserted else { throw ZAIUsageError.invalidResponse }
                continue
            }
            let resolved = try resolvedModel(model, pricing: pricing)
            guard seenModels.insert(resolved.id).inserted, !axisDays.isEmpty,
                  let cached = model.cachedInputTokensUsage, cached.count == axisDays.count,
                  let input = model.uncachedInputTokensUsage, input.count == axisDays.count,
                  let output = model.outputTokensUsage, output.count == axisDays.count else {
                throw ZAIUsageError.invalidResponse
            }
            let reported = model.totalTokensUsage ?? model.tokensUsage
            if let reported, reported.count != axisDays.count { throw ZAIUsageError.invalidResponse }
            for index in axisDays.indices {
                guard let tokens = UsageLogNumbers.sum(cached[index].value, input[index].value, output[index].value),
                      reported == nil || reported?[index].value == tokens,
                      let nextTokens = UsageLogNumbers.sum(days[axisDays[index]]!.tokens, tokens) else {
                    throw ZAIUsageError.invalidResponse
                }
                var day = days[axisDays[index]]!
                day.tokens = nextTokens
                if tokens > 0 {
                    if let rates = resolved.rates,
                       cached[index].value == 0 || rates.cacheReadIsExplicit,
                       let current = day.costUSD {
                        let breakdown = TokenBreakdown(
                            input: input[index].value, cacheRead: cached[index].value, output: output[index].value
                        )
                        let cost = rates.costDollars(for: breakdown, applyLongContextRates: false)
                        guard cost.isFinite, cost >= 0, (current + cost).isFinite else {
                            throw ZAIUsageError.invalidResponse
                        }
                        day.costUSD = current + cost
                    } else {
                        day.costUSD = nil
                    }
                }
                days[axisDays[index]] = day
            }
        }
        if seenModels.isEmpty {
            for key in window.days {
                days[key]?.tokensComplete = false
                days[key]?.costUSD = nil
            }
        }
        return Parsed(days: days)
    }

    private static func validatedAxis(
        _ axis: [String], window: ZAIDetailWindow
    ) throws -> (days: [String], completeHourly: Bool) {
        var seen = Set<String>()
        let allowedDays = Set(window.days)
        let days = try axis.map { value in
            if window.hourly {
                let parts = value.split(whereSeparator: { $0 == " " || $0 == "T" })
                guard parts.count == 1 || (parts.count == 2 && String(parts[0]) == window.days[0]),
                      let time = parts.last,
                      time.range(of: #"^(?:[01][0-9]|2[0-3]):00(?::00)?$"#, options: .regularExpression) != nil,
                      seen.insert(String(time.prefix(2))).inserted else { throw ZAIUsageError.invalidResponse }
                return window.days[0]
            }
            guard allowedDays.contains(value), seen.insert(value).inserted else {
                throw ZAIUsageError.invalidResponse
            }
            return value
        }
        let complete = !window.hourly || (0...(window.hourlyThrough ?? 23)).allSatisfy {
            seen.contains(String(format: "%02d", $0))
        }
        return (days, complete)
    }

    private static func resolvedModel(_ model: Model, pricing: ModelPricing) throws -> (id: String, rates: ModelRates?) {
        let code = canonicalID(model.modelCode, pricing: pricing)
        let name = canonicalID(model.modelName, pricing: pricing)
        let codeRates = code.flatMap { exactRates($0, pricing: pricing) }
        let nameRates = name.flatMap { exactRates($0, pricing: pricing) }
        if let code, let name, code != name, codeRates != nil, nameRates != nil {
            throw ZAIUsageError.invalidResponse
        }
        if let code { return (code, codeRates) }
        if let name, let nameRates { return (name, nameRates) }
        let rawCode = model.modelCode?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let rawName = model.modelName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard let id = code ?? name ?? rawCode ?? rawName else {
            throw ZAIUsageError.invalidResponse
        }
        return (id.lowercased(), nil)
    }

    private static func canonicalID(_ value: String?, pricing: ModelPricing) -> String? {
        guard var name = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !name.isEmpty else {
            return nil
        }
        for prefix in ["zai/", "z-ai/"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        guard name.range(of: #"^glm-[a-z0-9][a-z0-9.-]*$"#, options: .regularExpression) != nil else { return nil }
        let canonical = pricing.supplement.canonicalName(for: name) ?? name
        return canonical.hasPrefix("zai/") ? String(canonical.dropFirst(4)) : canonical
    }

    private static func exactRates(_ model: String, pricing: ModelPricing) -> ModelRates? {
        let scoped = "zai/" + model
        // bare supplement의 GLM 항목은 직영 요율. 외부 catalog는 Z.ai 명시 키만 허용하여 reseller·fuzzy 오가격 방지.
        return pricing.supplement.pricing[scoped] ?? pricing.supplement.pricing[model]
            ?? pricing.primary.findExact(scoped)?.rates ?? pricing.secondary.findExact(scoped)?.rates
    }

    private static func aggregateBucket(_ model: Model) -> String? {
        let code = model.modelCode?.lowercased().replacingOccurrences(of: "_", with: "")
        switch code {
        case "cachedinput", "cacheinput": return "cached"
        case "uncachedinput": return "uncached"
        case "output", "outputtokens": return "output"
        default: break
        }
        switch model.modelName?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "缓存": return "cached"
        case "未缓存": return "uncached"
        case "输出": return "output"
        default: return nil
        }
    }

    private struct Envelope: Decodable {
        let code: Int?
        let success: Bool?
        let data: Detail?
    }

    private struct Detail: Decodable {
        let modelUsage: Usage?
    }

    private struct Usage: Decodable {
        let xTime: [String]
        let modelDataList: [Model]
    }

    private struct Model: Decodable {
        let modelCode: String?
        let modelName: String?
        let cachedInputTokensUsage: [Count]?
        let uncachedInputTokensUsage: [Count]?
        let outputTokensUsage: [Count]?
        let totalTokensUsage: [Count]?
        let tokensUsage: [Count]?
    }

    private struct Count: Decodable {
        let value: Int

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let number = (try? container.decode(Int.self))
                ?? (try? container.decode(String.self)).flatMap { UsageLogNumbers.count($0) }
            guard let number, number >= 0 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid token count")
            }
            value = number
        }
    }
}
