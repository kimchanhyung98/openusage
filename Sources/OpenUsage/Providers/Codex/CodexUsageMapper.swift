import Foundation

struct CodexMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum CodexUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs
    /// Codex flex credit 1개당 4¢ — credits line은 dollar 값 선행 (JS plugin의 `CREDIT_USD_RATE` mirror).
    static let creditUSDRate = 0.04

    static func mapUsageResponse(
        _ response: HTTPResponse,
        resetCredits: HTTPResponse? = nil,
        now: Date = Date()
    ) throws -> CodexMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: CodexAuthError.tokenExpired,
            requestFailed: { CodexUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw CodexUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        let rateLimit = body["rate_limit"] as? [String: Any]
        lines.append(contentsOf: classifiedWindowLines(
            rateLimit: rateLimit,
            labels: (session: "Session", weekly: "Weekly"),
            headerPercents: (
                primary: ProviderParse.number(response.header("x-codex-primary-used-percent")),
                secondary: ProviderParse.number(response.header("x-codex-secondary-used-percent"))
            ),
            now: now
        ))

        // Model별 limit(예: GPT-5.3-Codex-Spark)은 별도 `additional_rate_limits` 배열 — Spark / Spark Weekly meter로 노출 (issue #796).
        lines.append(contentsOf: sparkLines(body: body, now: now))

        // On-demand reset credit은 Credits 앞에 표시 — count는 raw 전달(menu-bar tile과 동일 숫자), 각 credit의 expiry는 `expiriesAt`로 hover tooltip에 노출.
        if let resets = readResetCredits(body: body, resetCredits: resetCredits) {
            lines.append(.values(
                label: "Rate Limit Resets",
                values: [MetricValue(number: Double(resets.count), kind: .count, label: "available")],
                expiriesAt: resets.expiries
            ))
        }

        if let remaining = readCreditsRemaining(response: response, body: body) {
            lines.append(.values(label: "Credits", values: creditValues(remaining: remaining)))
        }

        // "no usage data" badge는 `CodexProvider.probe`가 스캔된 spend line *뒤에* 추가 — 빈 live 응답의 badge가 Today/Yesterday와 공존 불가.
        return CodexMappedUsage(plan: formatCodexPlan(body["plan_type"]), lines: lines)
    }

    private static func progress(
        label: String,
        used: Double,
        resetWindow: [String: Any]?,
        now: Date,
        periodDurationMs: Int
    ) -> MetricLine {
        .progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(resetWindow, now: now),
            periodDurationMs: periodDurationMs
        )
    }

    /// Rate-limit window 1개 → percent-used meter, `usedPercent` 없으면 `nil` — Session/Weekly/Spark 경로가 공유하는 단일 구성.
    private static func windowLine(
        label: String,
        usedPercent: Double?,
        window: [String: Any]?,
        defaultPeriodMs: Int,
        now: Date
    ) -> MetricLine? {
        guard let usedPercent else { return nil }
        let periodDurationMs = readPeriodMs(window) ?? defaultPeriodMs
        return progress(
            label: label,
            used: usedPercent,
            resetWindow: window,
            now: now,
            periodDurationMs: periodDurationMs
        )
    }

    private enum WindowKind {
        case session
        case weekly
    }

    private struct WindowCandidate {
        var window: [String: Any]
        var usedPercent: Double?
        var fallbackKind: WindowKind
    }

    /// Session/Weekly window 분류 — 명시적 duration 우선 (Codex가 단독 weekly limit을 primary slot으로 옮기는 경우 대응).
    /// primary=session / secondary=weekly slot 매핑은 duration을 생략하거나 낯선 값을 쓰는 payload용 호환 fallback.
    private static func classifiedWindowLines(
        rateLimit: [String: Any]?,
        labels: (session: String, weekly: String),
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date
    ) -> [MetricLine] {
        let candidates = [
            windowCandidate(rateLimit?["primary_window"], headerPercent: headerPercents.primary, fallbackKind: .session),
            windowCandidate(rateLimit?["secondary_window"], headerPercent: headerPercents.secondary, fallbackKind: .weekly)
        ].compactMap { $0 }

        return [
            classifiedWindowLine(kind: .session, label: labels.session, candidates: candidates, now: now),
            classifiedWindowLine(kind: .weekly, label: labels.weekly, candidates: candidates, now: now)
        ].compactMap { $0 }
    }

    private static func windowCandidate(
        _ value: Any?,
        headerPercent: Double?,
        fallbackKind: WindowKind
    ) -> WindowCandidate? {
        guard let window = value as? [String: Any] ?? (headerPercent == nil ? nil : [:]) else { return nil }
        return WindowCandidate(
            window: window,
            usedPercent: ProviderParse.number(window["used_percent"]) ?? headerPercent,
            fallbackKind: fallbackKind
        )
    }

    private static func classifiedWindowLine(
        kind: WindowKind,
        label: String,
        candidates: [WindowCandidate],
        now: Date
    ) -> MetricLine? {
        let exact = candidates.first { exactKind(for: $0.window) == kind }
        let fallback = candidates.first { exactKind(for: $0.window) == nil && $0.fallbackKind == kind }
        guard let candidate = exact ?? fallback else { return nil }
        let defaultPeriodMs = kind == .session ? sessionPeriodMs : weeklyPeriodMs
        return windowLine(
            label: label,
            usedPercent: candidate.usedPercent,
            window: candidate.window,
            defaultPeriodMs: defaultPeriodMs,
            now: now
        )
    }

    private static func exactKind(for window: [String: Any]) -> WindowKind? {
        guard let periodMs = readPeriodMs(window) else { return nil }
        switch periodMs {
        case sessionPeriodMs: return .session
        case weeklyPeriodMs: return .weekly
        default: return nil
        }
    }

    /// `additional_rate_limits`의 Spark(및 향후 model별) limit — 각 entry의 `rate_limit`이 primary/secondary window shape를 재사용하므로 core Session/Weekly 경로와 동일하게 파싱.
    /// 비-dictionary·null 요소는 유효한 형제를 버리지 않고 skip; Spark entry 없으면 빈 목록 반환 — 해당 row는 "No data".
    private static func sparkLines(body: [String: Any], now: Date) -> [MetricLine] {
        guard let rawEntries = body["additional_rate_limits"] as? [Any] else { return [] }
        let entries = rawEntries.compactMap { $0 as? [String: Any] }
        guard let spark = entries.first(where: isSparkEntry),
              let rateLimit = spark["rate_limit"] as? [String: Any]
        else {
            return []
        }

        return classifiedWindowLines(
            rateLimit: rateLimit,
            labels: (session: "Spark", weekly: "Spark Weekly"),
            now: now
        )
    }

    /// Spark limit entry 판별 — `limit_name`("GPT-5.3-Codex-Spark") 또는 `metered_feature`를 case-insensitive 매칭, 한쪽 표기 변경에도 해석 유지.
    private static func isSparkEntry(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]]
            .compactMap { ($0 as? String)?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = ProviderParse.number(window["reset_at"]) {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = ProviderParse.number(window["reset_after_seconds"]) {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func readPeriodMs(_ window: [String: Any]?) -> Int? {
        guard let window else { return nil }
        guard let seconds = ProviderParse.number(window["limit_window_seconds"]) else { return nil }
        return Int(seconds * 1000)
    }

    /// Flex credit을 raw 값으로 — floored count와 dollar 값(count × 4¢), "$32.84 · 821 credits" 형태로 결합 표시.
    /// count를 pricing *전에* floor — Codex CLI/plugin과 dollar 일치. 음수 잔액은 0으로 clamp — "$0.00 · 0 credits"는 측정된 zero, "No data" 아님.
    static func creditValues(remaining: Double) -> [MetricValue] {
        let credits = max(0, Int(remaining.rounded(.down)))
        let usd = Double(credits) * creditUSDRate
        return [
            MetricValue(number: usd, kind: .dollars),
            MetricValue(number: Double(credits), kind: .count, label: "credits")
        ]
    }

    /// On-demand reset credit — floored available count + still-available credit들의 expiry (soonest-first, hover tooltip용).
    /// per-credit expiry를 유일하게 제공하는 전용 `/rate-limit-reset-credits` payload 우선, 없으면 usage body의 count-only object로 fallback. 비numeric count는 row 전체 skip.
    static func readResetCredits(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> (count: Int, expiries: [Date])? {
        guard let source = resetCreditsSource(body: body, resetCredits: resetCredits),
              let count = ProviderParse.number(source["available_count"]), count >= 0
        else {
            return nil
        }
        return (Int(count.rounded(.down)), availableExpiries(in: source["credits"]))
    }

    /// count·expiry를 읽을 source — 전용 endpoint body가 usable(2xx, 파싱 가능, *numeric* `available_count`)일 때만 채택, 아니면 usage body의 embedded object.
    /// bare nil-check 금지 — JSON `null`은 `NSNull`(non-nil)이라 unusable한 전용 body를 선택해 usage-body count로의 fallback을 막음.
    private static func resetCreditsSource(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> [String: Any]? {
        if let resetCredits, (200..<300).contains(resetCredits.statusCode),
           let dedicated = ProviderParse.jsonObject(resetCredits.body),
           ProviderParse.number(dedicated["available_count"]) != nil {
            return dedicated
        }
        return body["rate_limit_reset_credits"] as? [String: Any]
    }

    /// Still-available credit들의 `expires_at` (soonest-first). `status`는 upstream optional — 명시적 non-available("consumed"/"expired")만 제외, status 없는 credit은 유지.
    /// `== "available"` hard filter는 status 생략 응답에서 expiry 목록(tooltip + 24h 경고) 전체를 비움. `expires_at`은 ISO-8601 문자열 또는 epoch 숫자로 파싱.
    private static func availableExpiries(in value: Any?) -> [Date] {
        guard let credits = value as? [[String: Any]] else { return [] }
        return credits
            .filter { credit in
                guard let status = credit["status"] as? String else { return true }
                return status == "available"
            }
            .compactMap { parseExpiry($0["expires_at"]) }
            .sorted()
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = OpenUsageISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func readCreditsRemaining(response: HTTPResponse, body: [String: Any]) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = ProviderParse.number(credits["balance"]) {
                return balance
            }
            if credits["has_credits"] as? Bool == false {
                return 0
            }
        }
        return ProviderParse.number(response.header("x-codex-credits-balance"))
    }

    static func formatCodexPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite":
            return "Pro 5x"
        case "pro":
            return "Pro 20x"
        default:
            return raw.titleCased(separator: { $0 == "_" })
        }
    }

}

enum CodexUsageError: Error, LocalizedError, Equatable {
    case requestFailed(Int)
    case invalidResponse
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        }
    }
}
