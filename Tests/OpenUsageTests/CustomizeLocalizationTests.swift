import XCTest
@testable import OpenUsage

final class CustomizeLocalizationTests: XCTestCase {
    func testOpenActionPreservesTheProviderNameInEveryLanguage() {
        let name = "Claude: 50% 개인 %@"
        let expected: [LanguageSetting: String] = [
            .english: "Open \(name)",
            .korean: "\(name) 열기",
            .japanese: "\(name)を開く"
        ]

        for language in LanguageSetting.allCases {
            let actual = L10n.withLanguage(language) { L10n.customize("Open %@", name) }
            XCTAssertEqual(actual, expected[language])
        }
    }

    func testMetricCountsAndPinLimitUseTranslatedNumberPlaceholders() {
        let expected: [LanguageSetting: [String]] = [
            .english: ["1 metric", "3 metrics", "Up to 2 stars per provider"],
            .korean: ["지표 1개", "지표 3개", "프로바이더당 최대 2개 고정 가능"],
            .japanese: ["指標 1 件", "指標 3 件", "プロバイダーごとに最大 2 件まで固定できます"]
        ]

        for language in LanguageSetting.allCases {
            let actual = L10n.withLanguage(language) {
                [
                    L10n.customize("%lld metric", 1),
                    L10n.customize("%lld metrics", 3),
                    L10n.customize("Up to %lld stars per provider", 2)
                ]
            }
            XCTAssertEqual(actual, expected[language])
        }
    }
}
