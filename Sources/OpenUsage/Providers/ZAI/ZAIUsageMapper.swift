import Foundation

/// Z.ai `/api/monitor/usage/quota/limit` payload와 `/api/biz/subscription/list`의 plan 이름을 metric line으로 매핑.
/// sub-daily `TOKENS_LIMIT`은 session meter, multi-day는 weekly meter, `TIME_LIMIT`은 web-search count meter.
/// 두 endpoint 모두 Z.ai 자체 UI가 쓰는 비공개 내부 API — mapper는 순수(I/O 없음)라 sample payload로 테스트 가능.
enum ZAIUsageMapper {
    /// 월간 web-search cycle 1회의 밀리초 (Z.ai 보고값 `unit: 5, number: 1`).
    /// session/weekly meter는 payload의 실제 window 사용(`classifyTokenWindow` 참고) — 이 상수는 web-search 행과 widget-descriptor 기본값 전용.
    static let monthlyPeriodMs = 30 * 24 * 60 * 60 * 1000

    /// quota + subscription payload에서 `(plan, lines)` 생성.
    /// `subscription`은 `nil` 가능(best-effort), `limits`는 1~3개 — 존재하는 것만 매핑해 web search 없는 plan도 session meter 표시.
    static func map(quotaBody: Data, subscriptionBody: Data?) throws -> (plan: String?, lines: [MetricLine]) {
        let plan = subscriptionBody.flatMap { planName(from: $0) }
        let lines = try mapQuota(quotaBody)
        return (plan, lines)
    }

    /// 2xx quota body가 "유효 key, GLM Coding Plan 없음" 신호(`{"success":false,…,"msg":"…coding plan"}`)인지 판정.
    /// 구조화된 `success:false`와 메시지의 "coding plan" 문구(localize돼도 ASCII)를 함께 매칭 — 무관한 business 실패의 오탐 방지.
    static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// quota payload에서 Session + Weekly + Web Searches meter 생성.
    /// 필수 값 누락은 0 사용량이 아닌 invalid response — 명시적 빈 배열은 유효한 no-data 상태.
    static func mapQuota(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ZAIUsageError.invalidResponse
        }
        // limits 배열은 `data.limits` 하위 — legacy plugin처럼 `data` wrapper 없는 root 직접 형태도 허용
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ZAIUsageError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageError.invalidResponse
        }
        guard !limits.isEmpty else {
            return [.noUsageData]
        }

        var lines: [MetricLine] = []
        var sawRecognizedLimit = false

        // TOKENS_LIMIT entry를 window 길이로 분리 — sub-daily는 session, multi-day는 weekly, 둘 다 percentage meter
        let tokenLimits = limits.filter { ($0["type"] as? String) == "TOKENS_LIMIT" || ($0["name"] as? String) == "TOKENS_LIMIT" }
        for entry in tokenLimits {
            guard let window = try classifyTokenWindow(entry) else { continue }
            sawRecognizedLimit = true
            switch window {
            case .session(let periodMs):
                lines.append(try percentLine(entry, label: "Session", periodMs: periodMs))
            case .weekly(let periodMs):
                lines.append(try percentLine(entry, label: "Weekly", periodMs: periodMs))
            }
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            sawRecognizedLimit = true
            lines.append(try webSearchLine(from: web))
        }

        guard !lines.isEmpty else {
            if sawRecognizedLimit { throw ZAIUsageError.invalidResponse }
            return [.noUsageData]
        }
        return lines
    }

    /// 첫 유효 subscription entry의 `productName` (예: "GLM Coding Max").
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return name
    }

    // MARK: - Private

    /// `TOKENS_LIMIT` entry의 window가 매핑되는 meter 구분.
    /// window는 `(unit, number)` 쌍으로 인코딩(`unit: 3` 시간, `unit: 6` 주, `unit: 5` 월) — sub-daily는 session, multi-day는 weekly.
    /// 미지의 unit은 무시 — 새 Z.ai window가 이해 가능한 unit의 meter를 가리지 못하게 함.
    private enum TokenWindow {
        case session(periodMs: Int)
        case weekly(periodMs: Int)
    }

    private static func classifyTokenWindow(_ entry: [String: Any]) throws -> TokenWindow? {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]),
              number > 0 else {
            throw ZAIUsageError.invalidResponse
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        case 5: unitMs = 30 * 24 * 60 * 60 * 1000
        default: return nil
        }
        let duration = unitMs * number
        guard duration >= 1, duration < Double(Int.max) else {
            throw ZAIUsageError.invalidResponse
        }
        let periodMs = Int(duration)
        // sub-daily → session, multi-day → weekly — 계산된 window를 함께 실어 meter cadence가 하드코딩 상수 대신 payload를 반영
        if periodMs < 24 * 60 * 60 * 1000 {
            return .session(periodMs: periodMs)
        }
        return .weekly(periodMs: periodMs)
    }

    /// `TOKENS_LIMIT` entry에서 percentage meter(Session 또는 Weekly) 생성.
    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawPercentage = ProviderParse.number(entry["percentage"]) else {
            throw ZAIUsageError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// TIME_LIMIT → 월간 web-search/reader 호출의 count meter(used/limit).
    private static func webSearchLine(from entry: [String: Any]) throws -> MetricLine {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0,
              limit >= 0 else {
            throw ZAIUsageError.invalidResponse
        }
        // 현행 payload의 TIME_LIMIT에는 nextResetTime(월간 갱신) 존재 — 있으면 실제 reset countdown, 없으면 "monthly" cadence 표기
        let resetsAt = ProviderParse.number(entry["nextResetTime"]).map { epochMsToDate($0) }
        return .progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: monthlyPeriodMs
        )
    }

    /// limit entry는 `type` 또는 `name`으로 매칭 — Z.ai payload가 revision에 따라 두 필드를 혼용.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }

    /// `nextResetTime`은 epoch 밀리초로 도착 (예: `1770648402389`).
    private static func epochMsToDate(_ ms: Double) -> Date {
        Date(timeIntervalSince1970: ms / 1000)
    }
}
