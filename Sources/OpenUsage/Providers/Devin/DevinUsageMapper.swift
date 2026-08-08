import Foundation

struct DevinMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum DevinUsageMapper {
    static let dayPeriodMs = MetricPeriod.dayMs
    static let weekPeriodMs = MetricPeriod.weekMs

    static func mapUserStatusResponse(_ response: HTTPResponse) throws -> DevinMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body),
              let userStatus = body["userStatus"] as? [String: Any]
        else {
            throw DevinUsageError.invalidResponse
        }
        return try mapUserStatus(userStatus)
    }

    static func mapUserStatus(_ userStatus: [String: Any]) throws -> DevinMappedUsage {
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = readTrimmedString(planInfo["planName"]) ?? "Unknown"
        let hideDailyQuota = ProviderParse.bool(planInfo["hideDailyQuota"]) == true

        let dailyRemaining = ProviderParse.number(planStatus["dailyQuotaRemainingPercent"])
        let weeklyRemaining = ProviderParse.number(planStatus["weeklyQuotaRemainingPercent"])
        let dailyReset = hideDailyQuota ? nil : unixSecondsToDate(planStatus["dailyQuotaResetAtUnix"])
        let weeklyReset = unixSecondsToDate(planStatus["weeklyQuotaResetAtUnix"])
        let extraUsageBalance = dollarsFromMicros(planStatus["overageBalanceMicros"])

        var lines: [MetricLine] = []
        if !hideDailyQuota,
           let dailyRemaining {
            lines.append(quotaLine(
                label: "Daily quota",
                remaining: dailyRemaining,
                resetsAt: dailyReset,
                periodDurationMs: dayPeriodMs
            ))
        }

        if let weeklyRemaining {
            lines.append(quotaLine(
                label: "Weekly quota",
                remaining: weeklyRemaining,
                resetsAt: weeklyReset,
                periodDurationMs: weekPeriodMs
            ))
        } else if hideDailyQuota,
                  let dailyRemaining {
            // 응답에 weekly quota 부재 시 숨겨진 daily quota를 Weekly 행으로 표시 (remaining→used 반전은 동일)
            lines.append(quotaLine(
                label: "Weekly quota",
                remaining: dailyRemaining,
                resetsAt: weeklyReset,
                periodDurationMs: weekPeriodMs
            ))
        }

        if let extraUsageBalance {
            // 숫자 원값 유지 — `MetricFormatter`의 compact 표기("$1.2K left")를 그대로 적용받기 위함
            lines.append(.values(label: "Extra usage balance", values: [MetricValue(number: extraUsageBalance, kind: .dollars)]))
        }

        guard !lines.isEmpty else {
            throw DevinUsageError.quotaUnavailable
        }

        return DevinMappedUsage(plan: plan, lines: lines)
    }

    /// Devin이 보고하는 remaining percent를 `100 - remaining`(clamp)으로 반전한 used percent 행 생성.
    private static func quotaLine(label: String, remaining: Double, resetsAt: Date?, periodDurationMs: Int) -> MetricLine {
        .progress(
            label: label,
            used: ProviderParse.clampPercent(100 - remaining),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodDurationMs
        )
    }

    private static func unixSecondsToDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// micros 값을 달러 단위 overage balance로 변환.
    /// 필드 부재·비숫자일 때만 `nil` — 0 balance는 실측 0으로 유지("$0.00" 표시).
    private static func dollarsFromMicros(_ value: Any?) -> Double? {
        guard let micros = ProviderParse.number(value) else { return nil }
        return max(0, micros) / 1_000_000
    }

    private static func readTrimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DevinUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "Devin quota data unavailable. Try again later."
        }
    }
}
