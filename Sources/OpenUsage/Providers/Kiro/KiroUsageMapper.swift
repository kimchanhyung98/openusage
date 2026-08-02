import Foundation

struct KiroMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum KiroUsageMapper {
    static let billingPeriodMs = 30 * 24 * 60 * 60 * 1000

    static func map(_ data: Data) throws -> KiroMappedUsage {
        guard let root = ProviderParse.jsonObject(data) else {
            throw KiroUsageError.invalidResponse
        }
        return try map(root)
    }

    static func map(_ root: [String: Any]) throws -> KiroMappedUsage {
        guard let rawBreakdowns = root["usageBreakdownList"] as? [Any] else {
            throw KiroUsageError.invalidResponse
        }

        var creditLine: MetricLine?
        for raw in rawBreakdowns {
            guard let breakdown = raw as? [String: Any] else {
                throw KiroUsageError.invalidResponse
            }
            guard (breakdown["resourceType"] as? String)?.uppercased() == "CREDIT" else {
                continue
            }
            guard creditLine == nil else { throw KiroUsageError.invalidResponse }

            let used = ProviderParse.number(breakdown["currentUsageWithPrecision"])
                ?? ProviderParse.number(breakdown["currentUsage"])
            let limit = ProviderParse.number(breakdown["usageLimitWithPrecision"])
                ?? ProviderParse.number(breakdown["usageLimit"])
            guard let used, let limit, used >= 0, limit > 0 else {
                throw KiroUsageError.invalidResponse
            }
            let reset = (
                ProviderParse.number(breakdown["nextDateReset"])
                    ?? ProviderParse.number(root["nextDateReset"])
            ).map(Date.init(timeIntervalSince1970:))
            creditLine = .progress(
                label: "Credits",
                used: used,
                limit: limit,
                format: .count(suffix: "credits"),
                resetsAt: reset,
                periodDurationMs: billingPeriodMs
            )
        }

        guard let creditLine else { throw KiroUsageError.quotaUnavailable }
        let plan: String?
        if let subscription = root["subscriptionInfo"] {
            guard let object = subscription as? [String: Any] else {
                throw KiroUsageError.invalidResponse
            }
            plan = (object["subscriptionTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } else {
            plan = nil
        }
        return KiroMappedUsage(plan: plan, lines: [creditLine])
    }
}
