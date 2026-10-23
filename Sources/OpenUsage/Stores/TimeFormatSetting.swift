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
        case .auto: return L10n.settings("Auto")
        case .twelveHour: return L10n.settings("12-hour")
        case .twentyFourHour: return L10n.settings("24-hour")
        }
    }

    /// 표시 언어와 시간 주기를 분리. Auto는 시스템 주기, 나머지는 명시 선택 준수.
    func shortTime(_ date: Date, base: Locale = L10n.locale, systemLocale: Locale = .current) -> String {
        var components = Locale.Components(locale: base)
        switch self {
        case .auto:
            components.hourCycle = systemLocale.hourCycle
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
