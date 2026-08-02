import Foundation

struct KimiMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum KimiUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
    private static let planNamesByLevel = [
        "LEVEL_FREE": "Adagio",
        "LEVEL_BASIC": "Moderato",
        "LEVEL_INTERMEDIATE": "Allegretto",
        "LEVEL_ADVANCED": "Allegro",
        "LEVEL_STANDARD": "Vivace"
    ]

    static func map(_ data: Data) throws -> KimiMappedUsage {
        guard let root = ProviderParse.jsonObject(data) else {
            throw KimiUsageError.invalidResponse
        }
        return try map(root)
    }

    static func map(_ root: [String: Any]) throws -> KimiMappedUsage {
        var lines: [MetricLine] = []

        if let limitsValue = root["limits"] {
            guard let limits = limitsValue as? [Any] else {
                throw KimiUsageError.invalidResponse
            }
            var sessionLine: MetricLine?
            for value in limits {
                guard let entry = value as? [String: Any] else {
                    throw KimiUsageError.invalidResponse
                }
                guard try windowDurationMs(entry["window"]) == sessionPeriodMs else { continue }
                guard sessionLine == nil else { throw KimiUsageError.invalidResponse }
                let detail: [String: Any]
                if let rawDetail = entry["detail"] {
                    guard let parsed = rawDetail as? [String: Any] else {
                        throw KimiUsageError.invalidResponse
                    }
                    detail = parsed
                } else {
                    detail = entry
                }
                sessionLine = try quotaLine(detail, label: "Session", periodDurationMs: sessionPeriodMs)
            }
            if let sessionLine { lines.append(sessionLine) }
        }

        if let usageValue = root["usage"] {
            guard let usage = usageValue as? [String: Any] else {
                throw KimiUsageError.invalidResponse
            }
            lines.append(try quotaLine(usage, label: "Weekly", periodDurationMs: weeklyPeriodMs))
        }

        guard !lines.isEmpty else { throw KimiUsageError.quotaUnavailable }
        return KimiMappedUsage(plan: plan(root), lines: lines)
    }

    private static func quotaLine(
        _ detail: [String: Any],
        label: String,
        periodDurationMs: Int
    ) throws -> MetricLine {
        guard let limit = ProviderParse.number(detail["limit"]), limit > 0 else {
            throw KimiUsageError.invalidResponse
        }

        let used: Double
        if let explicit = ProviderParse.number(detail["used"]) {
            used = explicit
        } else if let remaining = ProviderParse.number(detail["remaining"]) {
            used = limit - remaining
        } else {
            throw KimiUsageError.invalidResponse
        }
        guard used >= 0 else { throw KimiUsageError.invalidResponse }

        let reset = (detail["resetTime"] as? String).flatMap(OpenUsageISO8601.date(from:))
        return .progress(
            label: label,
            used: used / limit * 100,
            limit: 100,
            format: .percent,
            resetsAt: reset,
            periodDurationMs: periodDurationMs
        )
    }

    private static func windowDurationMs(_ value: Any?) throws -> Int? {
        guard let window = value as? [String: Any] else { return nil }
        guard let duration = ProviderParse.number(window["duration"]), duration > 0,
              let rawUnit = window["timeUnit"] as? String
        else {
            throw KimiUsageError.invalidResponse
        }
        let multiplier: Double
        switch rawUnit.uppercased() {
        case "TIME_UNIT_SECOND": multiplier = 1000
        case "TIME_UNIT_MINUTE": multiplier = 60 * 1000
        case "TIME_UNIT_HOUR": multiplier = 60 * 60 * 1000
        case "TIME_UNIT_DAY": multiplier = 24 * 60 * 60 * 1000
        default: return nil
        }
        let milliseconds = duration * multiplier
        guard milliseconds <= Double(Int.max) else { throw KimiUsageError.invalidResponse }
        return Int(milliseconds)
    }

    private static func plan(_ root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let raw = (membership["level"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }
        let normalized = raw.uppercased()
        if let planName = planNamesByLevel[normalized] {
            return planName
        }
        guard normalized != "LEVEL_UNSPECIFIED" else { return nil }
        let withoutPrefix = normalized.hasPrefix("LEVEL_") ? String(normalized.dropFirst(6)) : raw
        return withoutPrefix.titleCased(separator: { $0 == "_" || $0 == "-" }, lowercasingTail: true)
    }
}
