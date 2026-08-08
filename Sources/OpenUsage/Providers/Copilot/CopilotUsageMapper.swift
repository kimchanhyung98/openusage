import Foundation

struct CopilotMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    /// per-seat meter가 없는 org 관리(token-based-billing) seat이면 true — 실제 usage가 organization billing에 있으니 provider가 그쪽을 봐야 한다는 신호.
    /// 명시적 flag로 유지 — org 조회를 `lines`의 우연한 형태로 gate하지 않음 (issue #839: placeholder `overage_permitted`가 "Extra Usage: 0" 행을 끼워 넣어 조회를 막았던 회귀).
    var isOrgManagedSeat: Bool = false
}

/// `/copilot_internal/user` 응답을 meter로 normalize. 2026-06-01부터 모든 plan이 usage-based billing(AI Credits) — `premium_interactions` bucket이 **Credits**(월 allotment 대비 사용 %), 그 초과분이 **Extra Usage**(실제 Credits meter가 있을 때만 표시 — 포함 pool 없는 overage는 무의미).
/// 유료 plan의 `chat`/`completions`는 `-1` "unlimited" sentinel(억제), 무료 plan은 실제 count — 현행은 `quota_snapshots`, 구버전 응답은 `limited_user_quotas` 대 `monthly_quotas`.
/// zero-entitlement placeholder snapshot(Copilot Business token-based-billing seat의 응답)은 신호가 없어 오해를 부르는 "0% used" 막대 대신 억제.
enum CopilotUsageMapper {
    static let periodMs = MetricPeriod.monthMs

    static func map(_ response: HTTPResponse) throws -> CopilotMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body) else {
            throw CopilotUsageError.invalidResponse
        }
        return try map(body: body)
    }

    static func map(body: [String: Any]) throws -> CopilotMappedUsage {
        let plan = planLabel(body["copilot_plan"])
        let resetsAt = parseResetDate(body["quota_reset_date"])
            ?? parseResetDate(body["limited_user_reset_date"])

        var lines: [MetricLine] = []

        // metered premium pool은 "Credits", 초과분은 "Extra Usage". Extra Usage는 포함 pool에 상대적으로만 존재해 Credits meter에 종속 — org 관리 placeholder가 zero-entitlement bucket에 `overage_permitted: true`를 실을 수 있고, 그때 "0" 렌더는 무의미(과거 org-billing fallback을 막던 원인).
        let snapshots = body["quota_snapshots"] as? [String: Any]
        let premium = snapshots?["premium_interactions"]
        let creditsLine = snapshotLine(label: "Credits", premium, resetsAt: resetsAt)
        appendIfPresent(&lines, creditsLine)
        if creditsLine != nil {
            appendIfPresent(&lines, overageLine(premium))
        }

        // chat + completions: 무료는 실제 bucket별 count, 유료는 `-1` "unlimited" sentinel(`snapshotLine`이 억제). `quota_snapshots` 없는 구 무료 응답은 아래 `limited_user_quotas`/`monthly_quotas`로 fallback.
        appendIfPresent(&lines, snapshotLine(label: "Chat", snapshots?["chat"], resetsAt: resetsAt))
        appendIfPresent(&lines, snapshotLine(label: "Completions", snapshots?["completions"], resetsAt: resetsAt))

        // legacy 무료 tier 형태(`quota_snapshots` 이전): 월 한도 대비 remaining count. 아무것도 생성되지 않았을 때만 — 아니면 `limited_user_quotas`가 남은 유료 계정(Credits 있음, chat/completions는 unlimited로 억제)이 Credits 옆에 무료 tier meter를 잘못 표시.
        if lines.isEmpty {
            let limited = body["limited_user_quotas"] as? [String: Any]
            let monthly = body["monthly_quotas"] as? [String: Any]
            appendIfPresent(&lines, limitedLine(label: "Chat", remaining: limited?["chat"], total: monthly?["chat"], resetsAt: resetsAt))
            appendIfPresent(&lines, limitedLine(label: "Completions", remaining: limited?["completions"], total: monthly?["completions"], resetsAt: resetsAt))
        }

        // Copilot Business/token-based-billing seat는 per-seat quota 미노출 — 실패가 아닌 정당한 빈 상태. plan은 빈 meter와 함께 표시(타일은 "No data")해 dashboard가 plan을 식별. token-based-billing 표식 없는 진짜 빈/깨진 payload는 실제 문제라 크게 실패.
        guard !lines.isEmpty else {
            if ProviderParse.bool(body["token_based_billing"]) == true {
                return CopilotMappedUsage(plan: plan, lines: [], isOrgManagedSeat: true)
            }
            throw CopilotUsageError.quotaUnavailable
        }

        return CopilotMappedUsage(plan: plan, lines: lines)
    }

    // MARK: - Lines

    /// `quota_snapshots` bucket → percent-used meter, 억제 시 nil.
    /// 억제 대상: bucket 부재, `unlimited` 또는 `-1` sentinel(usage-based billing의 유료 chat·completions는 실제 meter가 없어 오해의 0% 대신 숨김), zero-entitlement placeholder(allotment 없는 무료 계정의 Credits 등).
    private static func snapshotLine(label: String, _ raw: Any?, resetsAt: Date?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any] else { return nil }

        let entitlement = ProviderParse.number(snapshot["entitlement"])
        let remaining = ProviderParse.number(snapshot["remaining"])

        // unlimited: 명시적 flag 또는 entitlement/remaining의 `-1` sentinel — 억제.
        if ProviderParse.bool(snapshot["unlimited"]) == true || entitlement == -1 || remaining == -1 {
            return nil
        }
        // zero entitlement = 실제 allotment 없음(token-based-billing placeholder, 무료의 Credits) — drop.
        if entitlement == 0 { return nil }

        let usedPercent: Double
        if let percentRemaining = ProviderParse.number(snapshot["percent_remaining"]) {
            usedPercent = ProviderParse.clampPercent(100 - percentRemaining)
        } else if let entitlement, entitlement > 0, let remaining {
            usedPercent = ProviderParse.clampPercent(100 - (remaining / entitlement) * 100)
        } else {
            return nil
        }

        return .progress(
            label: label,
            used: usedPercent,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// "Extra Usage" — 포함 Credits pool 초과로 소비한 premium interaction. 추가(overage) 지출 활성화(`overage_permitted`) 시에만 표시 — 그때는 실제 0도 "0"으로 표시(show-real-zeros 규칙), 비활성화면 진짜 N/A → nil("No data").
    /// endpoint가 spending cap을 노출하지 않아 meter가 아닌 unbounded count.
    private static func overageLine(_ raw: Any?) -> MetricLine? {
        guard let snapshot = raw as? [String: Any],
              ProviderParse.bool(snapshot["overage_permitted"]) == true
        else {
            return nil
        }
        let overage = max(0, ProviderParse.number(snapshot["overage_count"]) ?? 0)
        return .values(label: "Extra Usage", values: [MetricValue(number: overage, kind: .count)])
    }

    /// 무료 tier bucket: 월 한도 `total` 대비 `remaining` → percent-used meter. 양수 한도와 remaining이 모두 있어야 함 — 분모 없이 정직한 percentage 불가.
    private static func limitedLine(label: String, remaining: Any?, total: Any?, resetsAt: Date?) -> MetricLine? {
        guard let total = ProviderParse.number(total), total > 0,
              let remaining = ProviderParse.number(remaining)
        else {
            return nil
        }
        let used = max(0, total - remaining)
        return .progress(
            label: label,
            used: ProviderParse.clampPercent((used / total) * 100),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    private static func appendIfPresent(_ lines: inout [MetricLine], _ line: MetricLine?) {
        if let line { lines.append(line) }
    }

    // MARK: - Field helpers

    private static func planLabel(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.titleCased(separator: { $0 == "_" || $0 == " " || $0 == "-" }, lowercasingTail: true)
    }

    /// reset timestamp 파싱. 유료 tier는 ISO-8601 datetime(`quota_reset_date`, 소수점 초 포함 가능) — 공유 `OpenUsageISO8601` normalizer 처리. 무료 tier는 bare `yyyy-MM-dd`(`limited_user_reset_date`) — 여기 남은 유일한 Copilot 전용 fallback.
    private static func parseResetDate(_ value: Any?) -> Date? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let date = OpenUsageISO8601.date(from: raw) { return date }
        return dayOnlyFormatter.date(from: raw)
    }

    /// `nonisolated(unsafe)`는 안전: `DateFormatter`는 macOS 10.9+에서 thread-safe 문서화, 생성 후 불변 (`CursorUsageCSV`/`OpenUsageISO8601`과 동일 패턴).
    private nonisolated(unsafe) static let dayOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

enum CopilotUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case connectionFailed
    case requestFailed(Int)
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Copilot usage response invalid. Try again later."
        case .connectionFailed:
            return "Couldn't reach GitHub. Check your connection."
        case .requestFailed(let status):
            return "Copilot usage request failed (HTTP \(status)). Try again later."
        case .quotaUnavailable:
            return "Copilot usage data is unavailable for this account."
        }
    }
}
