import Foundation
import XCTest
@testable import OpenUsage

final class LanguageSettingTests: XCTestCase {
    func testLanguageChoicePersistsOnlyInProvidedDefaults() throws {
        let suite = "LanguageSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unchanged", forKey: "accountName")

        XCTAssertEqual(defaults.enumValue(forKey: LanguageSetting.key, default: LanguageSetting.fallback), .english)
        LanguageSetting.update(to: .japanese, defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: LanguageSetting.key), "ja")
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: "accountName"), "unchanged")
        XCTAssertEqual(defaults.enumValue(forKey: LanguageSetting.key, default: LanguageSetting.fallback), .japanese)

        defaults.set("unsupported", forKey: LanguageSetting.key)
        XCTAssertEqual(defaults.enumValue(forKey: LanguageSetting.key, default: LanguageSetting.fallback), .english)
    }

    func testFirstLaunchForcesEnglishWithoutChangingFreshInstallDetection() throws {
        let suite = "LanguageSettingTests.Launch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.setVolatileDomain(
            ["AppleLanguages": ["ja"], "unrelatedLaunchArgument": "keep"],
            forName: UserDefaults.argumentDomain
        )

        LanguageSetting.configureLaunch(defaults: defaults)

        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        XCTAssertEqual(defaults.string(forKey: "unrelatedLaunchArgument"), "keep")
        XCTAssertNil(defaults.string(forKey: LanguageSetting.key))
        XCTAssertTrue(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: suite))
    }

    func testSavedLanguageAppliesOnLaunchAndChangesWaitForTheNextLaunch() throws {
        let suite = "LanguageSettingTests.Relaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
            defaults.removePersistentDomain(forName: suite)
        }

        for language in LanguageSetting.allCases {
            LanguageSetting.update(to: language, defaults: defaults)
            LanguageSetting.configureLaunch(defaults: defaults)
            XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), [language.rawValue])
        }

        LanguageSetting.update(to: .korean, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ja"])
        XCTAssertNil(defaults.persistentDomain(forName: suite)?["AppleLanguages"])

        LanguageSetting.configureLaunch(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["ko"])

        defaults.set("unsupported", forKey: LanguageSetting.key)
        LanguageSetting.configureLaunch(defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
    }

    func testNativeNamesRemainRecognizableInEveryLanguage() {
        for language in LanguageSetting.allCases {
            L10n.withLanguage(language) {
                XCTAssertEqual(LanguageSetting.allCases.map(\.nativeName), ["English", "한국어", "日本語"])
            }
        }
    }

    func testScopedLanguageDoesNotOverwriteSavedSelection() {
        let saved = UserDefaults.standard.string(forKey: LanguageSetting.key)
        let active = LanguageSetting.active
        L10n.withLanguage(.korean) {
            XCTAssertEqual(L10n.common("Settings"), "설정")
            L10n.withLanguage(.japanese) {
                XCTAssertEqual(L10n.common("Settings"), "設定")
            }
            XCTAssertEqual(L10n.common("Settings"), "설정")
        }
        XCTAssertEqual(L10n.language, active)
        XCTAssertEqual(UserDefaults.standard.string(forKey: LanguageSetting.key), saved)
    }

    func testUnknownDynamicNamesRemainLiteral() {
        for language in LanguageSetting.allCases {
            L10n.withLanguage(language) {
                XCTAssertEqual(L10n.metrics("Private model 100% %@"), "Private model 100% %@")
            }
        }
    }

    func testDefaultAccountLabelDoesNotTranslateUserChosenNames() {
        L10n.withLanguage(.korean) {
            XCTAssertEqual(DashboardUsageAccountSelection.optionTitle(cardID: "claude", profileLabel: nil, accountName: nil), "기본 계정")
            XCTAssertEqual(DashboardUsageAccountSelection.optionTitle(cardID: "claude", profileLabel: "Default", accountName: nil), "Default")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(DashboardUsageAccountSelection.optionTitle(cardID: "claude", profileLabel: nil, accountName: nil), "デフォルト")
        }
    }
}
