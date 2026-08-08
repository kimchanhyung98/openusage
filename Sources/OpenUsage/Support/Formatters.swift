import Foundation

/// 사용량 표시용 공통 formatter: mode-aware deadline/reset 문구, compact duration, USD 통화.
enum Formatters {
    static func currency(_ amount: Double, fractionDigits: Int = 2) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = fractionDigits
        f.minimumFractionDigits = fractionDigits
        // fallback도 요청 precision 준수 — raw "$\(amount)"는 double의 전체 소수를 노출함.
        return f.string(from: amount as NSNumber) ?? "$\(String(format: "%.\(fractionDigits)f", amount))"
    }

    /// 앱 공통 compact 월/일 표기(예: "Jun 21") — localized, 연도 없음.
    static func monthDayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// 모든 "<verb> + when" 라벨이 공유하는 mode-aware deadline 문구.
    /// `.relative` → "<prefix> in 2d 6h", `.absolute` → "<prefix> today at 5:30 PM" 등; 임박 시 "<prefix> soon"으로 축약.
    static func deadlineLabel(
        _ prefix: String,
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let when = whenLabel(at: date, mode: mode, now: now, calendar: calendar) else { return nil }
        if when == imminent { return "\(prefix) \(when)" }
        switch mode {
        case .relative: return "\(prefix) in \(when)"
        case .absolute: return "\(prefix) \(when)"
        }
    }

    /// `deadlineLabel`과 reset-credit tooltip이 공유하는 verb 없는 "when" 문구.
    /// 임박(past-due 또는 ≤5분) 시 `imminent`, duration이 non-finite일 때만 `nil`.
    static func whenLabel(
        at date: Date,
        mode: ResetDisplayMode,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        switch mode {
        case .relative:
            let seconds = date.timeIntervalSince(now)
            if seconds <= 5 * 60 { return imminent }
            return compactDuration(seconds)
        case .absolute:
            guard date.timeIntervalSince(now) > 0 else { return imminent }
            let dayDiff = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: now),
                to: calendar.startOfDay(for: date)
            ).day ?? 0
            // wall-clock 부분은 사용자의 Auto/12h/24h 시간 형식 설정 준수.
            let time = TimeFormatSetting.current.shortTime(date)
            if dayDiff <= 0 { return "today at \(time)" }
            if dayDiff == 1 { return "tomorrow at \(time)" }
            return "\(monthDayLabel(date)) at \(time)"
        }
    }

    /// past-due이거나 ~5분 이내라 countdown이 무의미한 deadline의 축약 문구.
    static let imminent = "soon"

    static func resetRelativeLabel(until resetsAt: Date, now: Date = Date()) -> String? {
        deadlineLabel("Resets", at: resetsAt, mode: .relative, now: now)
    }

    static func resetAbsoluteLabel(at resetsAt: Date, now: Date = Date(), calendar: Calendar = .current) -> String? {
        deadlineLabel("Resets", at: resetsAt, mode: .absolute, now: now, calendar: calendar)
    }

    /// compact duration 표기 — "Xd Yh" / "Xh Ym" / "Xm".
    /// day 단위에서는 hours가 0이어도 항상 두 단위 표기("4d 0h"), minutes는 생략.
    static func compactDuration(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let totalMinutes = max(1, Int((seconds / 60).rounded(.up)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(minutes)m"
    }
}
