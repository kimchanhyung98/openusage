import Foundation

/// 표시 전용 번역. 저장값·API 식별자는 호출자가 원문으로 유지.
enum L10n {
    @TaskLocal private static var languageOverride: LanguageSetting?

    static var language: LanguageSetting { languageOverride ?? LanguageSetting.active }
    static var locale: Locale { language.locale }

    private static let bundles: [LanguageSetting: Bundle] = {
        let resources = Bundle.openUsageResources
        return Dictionary(uniqueKeysWithValues: LanguageSetting.allCases.compactMap { language in
            guard let url = resources.url(forResource: language.rawValue, withExtension: "lproj"),
                  let bundle = Bundle(url: url) else {
                AppLog.error(.config, "Missing localization resources for \(language.rawValue)")
                return nil
            }
            return (language, bundle)
        })
    }()

    static func common(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Common", arguments: arguments)
    }

    static func settings(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Settings", arguments: arguments)
    }

    static func accounts(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Accounts", arguments: arguments)
    }

    static func dashboard(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Dashboard", arguments: arguments)
    }

    static func customize(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Customize", arguments: arguments)
    }

    static func metrics(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Metrics", arguments: arguments)
    }

    static func errors(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, table: "Errors", arguments: arguments)
    }

    static func string(_ key: String, table: String, arguments: [CVarArg] = []) -> String {
        let english = bundles[.english]?.localizedString(forKey: key, value: key, table: table) ?? key
        let format = bundles[language]?.localizedString(forKey: key, value: english, table: table) ?? english
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

    /// 테스트와 기존 외부 출력 계약의 언어를 작업 범위 안에서 명시.
    static func withLanguage<Result>(_ language: LanguageSetting, operation: () throws -> Result) rethrows -> Result {
        try $languageOverride.withValue(language, operation: operation)
    }

    static func withLanguage<Result>(_ language: LanguageSetting, operation: () async throws -> Result) async rethrows -> Result {
        try await $languageOverride.withValue(language, operation: operation)
    }
}
