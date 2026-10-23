import Foundation

/// 표시 언어 선택. 실행 중인 언어는 고정하고 저장한 선택은 다음 실행부터 적용.
enum LanguageSetting: String, CaseIterable, Hashable, Sendable, UserDefaultsBacked {
    case english = "en"
    case korean = "ko"
    case japanese = "ja"

    static let key = "appLanguage"
    static let fallback = Self.english
    static let active = current

    var nativeName: String {
        switch self {
        case .english: "English"
        case .korean: "한국어"
        case .japanese: "日本語"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static func update(to language: Self, defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: key)
    }

    static func configureLaunch(defaults: UserDefaults = .standard) {
        let language = defaults.enumValue(forKey: key, default: fallback)
        // 앱의 선택만 사용하며 첫 실행은 영어. 영속 설정을 쓰지 않아 첫 설치 판별 유지.
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments["AppleLanguages"] = [language.rawValue]
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }
}
