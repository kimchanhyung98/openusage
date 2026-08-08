import Foundation

struct ClaudeMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    /// usage에 동반되는 provider header notice(amber 삼각형 + tooltip) — clean fetch면 `nil`.
    var warning: String?
}

enum ClaudeUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs

    static func mapUsageResponse(_ response: HTTPResponse, credentials: ClaudeOAuth, now: Date = Date()) throws -> ClaudeMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: ClaudeAuthError.tokenExpired,
            requestFailed: { ClaudeUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ClaudeUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        appendUsageWindow(body["five_hour"], label: "Session", periodDurationMs: sessionPeriodMs, to: &lines)
        appendUsageWindow(body["seven_day"], label: "Weekly", periodDurationMs: weeklyPeriodMs, to: &lines)
        appendUsageWindow(body["seven_day_sonnet"], label: "Sonnet", periodDurationMs: weeklyPeriodMs, to: &lines)
        appendScopedWeeklyLimit(body["limits"], modelName: "Fable", label: "Fable", to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)

        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: lines
        )
    }

    /// rate-limit 상태에서 last-good 부재 시의 snapshot — status badge + staleness note, 라이브 바 없음.
    static func rateLimitedUsage(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let waitText = retryText.map { "Rate limited, retry in ~\($0)" } ?? "Rate limited, try again later"
        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: [
                .badge(label: "Status", text: waitText, colorHex: "#F59E0B"),
                rateLimitedNote(retryAfterSeconds: retryAfterSeconds)
            ],
            warning: rateLimitedWarning(retryAfterSeconds: retryAfterSeconds)
        )
    }

    /// rate-limited 상태의 provider header 경고 — badge/note 라인이 레이아웃에 없어도 원인 표시,
    /// 수동 refresh 자제 안내(rate limit 연장 방지).
    static func rateLimitedWarning(retryAfterSeconds: Int?) -> String {
        let base = "Updates blocked by Anthropic. Be patient — manual refreshes will make it worse."
        guard let retryText = retryAfterSeconds.map(formatRateLimitMinutes) else { return base }
        return "\(base) Retrying in ~\(retryText)."
    }

    /// `user:profile` scope 없는 로그인(inference 전용 토큰)의 header 경고 — 재로그인으로
    /// Session/Weekly 복구 안내; 스캔된 spend 타일은 영향 없음.
    static let missingProfileScopeWarning = "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits."

    /// last-good snapshot에 덧붙는 rate-limited note(바의 stale 가능성 표시) — `rateLimitedUsage`와 문구 공유.
    static func rateLimitedNote(retryAfterSeconds: Int?) -> MetricLine {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let noteText = retryText.map { "Live usage rate limited - retry in ~\($0)" } ?? "Live usage rate limited - data may be stale"
        return .text(label: "Note", value: noteText)
    }

    static func parseRetryAfterSeconds(_ response: HTTPResponse, now: Date = Date()) -> Int? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return seconds
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            return max(0, Int(ceil(date.timeIntervalSince(now))))
        }
        return nil
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.titleCased(separator: { $0 == " " }, lowercasingTail: true)

        guard let tier = rateLimitTier,
              let match = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        return "\(base) \(tier[match])"
    }

    private static func appendUsageWindow(_ value: Any?, label: String, periodDurationMs: Int, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              let used = ProviderParse.number(object["utilization"])
        else {
            return
        }
        lines.append(.progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(object["resets_at"]),
            periodDurationMs: periodDurationMs
        ))
    }

    /// `limits` 배열의 model-scoped weekly limit(`kind: "weekly_scoped"`) — legacy top-level
    /// `seven_day_<model>` 키는 null 회귀, display name으로 행 조회; `percent`는 0–100.
    private static func appendScopedWeeklyLimit(_ limits: Any?, modelName: String, label: String, to lines: inout [MetricLine]) {
        guard let array = limits as? [Any] else { return }
        for entry in array {
            guard let object = entry as? [String: Any],
                  object["kind"] as? String == "weekly_scoped",
                  let scope = object["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  model["display_name"] as? String == modelName,
                  let used = ProviderParse.number(object["percent"])
            else { continue }
            lines.append(.progress(
                label: label,
                used: used,
                limit: 100,
                format: .percent,
                resetsAt: resetDate(object["resets_at"]),
                periodDurationMs: weeklyPeriodMs
            ))
            return
        }
    }

    private static func appendExtraUsage(_ value: Any?, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let usedCents = ProviderParse.number(object["used_credits"])
        else {
            return
        }

        let used = ProviderParse.centsToDollars(usedCents)
        if let limitCents = ProviderParse.number(object["monthly_limit"]), limitCents > 0 {
            lines.append(.progress(
                label: "Extra usage spent",
                used: used,
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars
            ))
        } else if used > 0 {
            // monthly cap 없음: unbounded spend를 raw로 전달 — `MetricFormatter`의 compact 포맷 적용.
            lines.append(.values(label: "Extra usage spent", values: [MetricValue(number: used, kind: .dollars)]))
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let date = OpenUsageISO8601.date(from: text) {
            return date
        }
        guard let number = ProviderParse.number(value), number.isFinite else {
            return nil
        }
        let milliseconds = abs(number) < 1e10 ? number * 1000 : number
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func formatRateLimitMinutes(_ seconds: Int) -> String {
        guard seconds > 0 else { return "now" }
        return "\(Int(ceil(Double(seconds) / 60)))m"
    }

}

private enum HTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

