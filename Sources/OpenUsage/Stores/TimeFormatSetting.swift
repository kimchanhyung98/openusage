import Foundation

/// 절대 reset label의 wall-clock 표기 방식 — 시스템 12/24시간 관례 또는 명시 override (원본 앱의 Auto/12h/24h 대응)
enum TimeFormatSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case auto
    case twelveHour = "12h"
    case twentyFourHour = "24h"

    static let key = "timeFormat"
    static var fallback: TimeFormatSetting { .twentyFourHour }

    // `current`(라이브로 읽는 저장 선택값)는 `UserDefaultsBacked` 제공

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .twelveHour: return "12-hour"
        case .twentyFourHour: return "24-hour"
        }
    }

    /// override를 반영한 short time 문자열 ("5:30 PM" / "17:30") — locale hour cycle 경유
    func shortTime(_ date: Date, base: Locale = .current) -> String {
        var components = Locale.Components(locale: base)
        switch self {
        case .auto:
            break
        case .twelveHour:
            components.hourCycle = .oneToTwelve
        case .twentyFourHour:
            components.hourCycle = .zeroToTwentyThree
        }
        return date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(components: components))
        )
    }
}
