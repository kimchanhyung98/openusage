import Foundation

/// OpenCode Go plan의 세 window — 공표 cap($12/rolling 5h, $30/week, $60/month) 대비 로컬 관측 spend.
/// `OpenCodeGoWindowMath`가 로컬 `opencode-go` 메시지에서 생성 — meter 전용, spend tile은 hosted 합산 spend 사용.
struct OpenCodeGoWindows: Sendable, Equatable {
    var sessionSpend: Double
    var sessionResetsAt: Date?
    var weeklySpend: Double
    var weeklyResetsAt: Date?
    var monthlySpend: Double
    var monthlyResetsAt: Date?
    var monthlyPeriodMs: Int?
}

/// rolling 5시간 session, UTC-ISO week(월요일 시작), 최초 Go 사용일의 day-of-month에 anchor된 month의 window 계산.
/// anchor 부재 시 calendar month fallback. 순수 UTC 기반 — `now`/anchor는 caller 주입으로 결정적·unit-test 가능.
enum OpenCodeGoWindowMath {
    static let fiveHoursMs = Double(MetricPeriod.sessionMs)
    static let weekMs = Double(MetricPeriod.weekMs)

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// 세 plan window의 spend·reset 시각 계산.
    /// `costs`: range 내 로컬 `opencode-go` assistant 메시지의 `(timestampMs, cost)` — window 안 행만 해당 window에 기여.
    /// `anchorMs`: monthly cycle anchor가 되는 최초 `opencode-go` 사용 시각(ms), `nil`이면 UTC calendar month.
    static func compute(costs: [(ms: Double, cost: Double)], anchorMs: Double?, now: Date) -> OpenCodeGoWindows {
        let nowMs = ms(now)

        let sessionStart = nowMs - fiveHoursMs
        let sessionSpend = sumRange(costs, start: sessionStart, end: nowMs)
        let oldestInSession = costs.lazy.filter { $0.ms >= sessionStart && $0.ms < nowMs }.map(\.ms).min()
        let sessionResetsAt = date(ms: (oldestInSession ?? nowMs) + fiveHoursMs)

        let weekStart = startOfUtcWeek(nowMs)
        let weekEnd = weekStart + weekMs
        let weeklySpend = sumRange(costs, start: weekStart, end: weekEnd)

        let month = anchoredMonthBounds(nowMs: nowMs, anchorMs: anchorMs)
        let monthlySpend = sumRange(costs, start: month.start, end: month.end)

        return OpenCodeGoWindows(
            sessionSpend: sessionSpend,
            sessionResetsAt: sessionResetsAt,
            weeklySpend: weeklySpend,
            weeklyResetsAt: date(ms: weekEnd),
            monthlySpend: monthlySpend,
            monthlyResetsAt: date(ms: month.end),
            monthlyPeriodMs: Int((month.end - month.start).rounded())
        )
    }

    private static func sumRange(_ costs: [(ms: Double, cost: Double)], start: Double, end: Double) -> Double {
        let total = costs.reduce(0.0) { partial, row in
            (row.ms >= start && row.ms < end) ? partial + row.cost : partial
        }
        // meter가 cap으로 나누기 전 float 합산 noise 제거를 위해 1/100 cent 단위로 snap
        return (total * 10000).rounded() / 10000
    }

    // MARK: - Week

    private static func startOfUtcWeek(_ nowMs: Double) -> Double {
        let startOfToday = utc.startOfDay(for: date(ms: nowMs))
        let weekday = utc.component(.weekday, from: startOfToday) // 1=일요일 … 7=토요일.
        let daysSinceMonday = (weekday + 5) % 7                   // 월요일→0, 일요일→6.
        let monday = utc.date(byAdding: .day, value: -daysSinceMonday, to: startOfToday) ?? startOfToday
        return ms(monday)
    }

    // MARK: - Month (anchored to earliest usage's day-of-month)

    private static func anchoredMonthBounds(nowMs: Double, anchorMs: Double?) -> (start: Double, end: Double) {
        guard let anchorMs, anchorMs.isFinite else {
            let components = utc.dateComponents([.year, .month], from: date(ms: nowMs))
            let start = utcDate(year: components.year!, month: components.month!, day: 1)
            let end = utcDate(year: components.year!, month: components.month! + 1, day: 1)
            return (ms(start), ms(end))
        }

        let anchor = date(ms: anchorMs)
        let nowComponents = utc.dateComponents([.year, .month], from: date(ms: nowMs))
        var year = nowComponents.year!
        var month = nowComponents.month! // 1부터 시작.
        var start = anchoredMonthStart(year: year, month: month, anchor: anchor)

        // anchor day-of-month가 오늘보다 뒤면 이번 달 anchored start가 미래에 위치 — 실제 live cycle은 지난달 시작
        if ms(start) > nowMs {
            (year, month) = shiftMonth(year: year, month: month, delta: -1)
            start = anchoredMonthStart(year: year, month: month, anchor: anchor)
        }
        let (nextYear, nextMonth) = shiftMonth(year: year, month: month, delta: 1)
        let end = anchoredMonthStart(year: nextYear, month: nextMonth, anchor: anchor)
        return (ms(start), ms(end))
    }

    /// 해당 월 내 anchored cycle 시작 — anchor의 day-of-month(월 길이로 clamp)와 time-of-day, UTC 기준.
    private static func anchoredMonthStart(year: Int, month: Int, anchor: Date) -> Date {
        let anchorParts = utc.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor)
        let day = min(anchorParts.day ?? 1, daysInMonth(year: year, month: month))
        return utcDate(
            year: year, month: month, day: day,
            hour: anchorParts.hour ?? 0, minute: anchorParts.minute ?? 0,
            second: anchorParts.second ?? 0, nanosecond: anchorParts.nanosecond ?? 0
        )
    }

    private static func shiftMonth(year: Int, month: Int, delta: Int) -> (year: Int, month: Int) {
        // 1-based `month`를 0-based로 바꿔 모듈러 연산 후 복원
        let total = year * 12 + (month - 1) + delta
        let normalizedMonth = ((total % 12) + 12) % 12
        return (Int((Double(total) / 12).rounded(.down)), normalizedMonth + 1)
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        let first = utcDate(year: year, month: month, day: 1)
        return utc.range(of: .day, in: .month, for: first)?.count ?? 28
    }

    private static func utcDate(
        year: Int, month: Int, day: Int,
        hour: Int = 0, minute: Int = 0, second: Int = 0, nanosecond: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month // 범위 밖 month/day는 Calendar가 정규화 (JS Date.UTC와 동일 동작)
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return utc.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private static func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }
    private static func date(ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
}
