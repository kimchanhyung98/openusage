import Foundation
import XCTest
@testable import OpenUsage

final class LocalizationResourceTests: XCTestCase {
    private let tables = ["Accounts", "Common", "Customize", "Dashboard", "Errors", "Metrics", "Settings"]

    func testEveryLanguageShipsTheSameCompleteTables() throws {
        for table in tables {
            let english = try strings(table: table, language: .english)
            XCTAssertFalse(english.isEmpty, table)
            for language in LanguageSetting.allCases {
                let translated = try strings(table: table, language: language)
                XCTAssertEqual(Set(translated.keys), Set(english.keys), "\(table)/\(language.rawValue)")
                for (key, value) in translated {
                    XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(table): \(key)")
                    XCTAssertEqual(
                        try placeholders(value), try placeholders(try XCTUnwrap(english[key])),
                        "\(table)/\(language.rawValue): \(key)"
                    )
                }
            }
        }
    }

    func testPackagedLookupUsesTheSelectedLanguage() {
        for (language, expected) in [(LanguageSetting.english, "Settings"), (.korean, "설정"), (.japanese, "設定")] {
            L10n.withLanguage(language) {
                XCTAssertEqual(L10n.common("Settings"), expected)
            }
        }
    }

    private func strings(table: String, language: LanguageSetting) throws -> [String: String] {
        let url = try XCTUnwrap(Bundle.openUsageResources.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language.rawValue))
        let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        return try XCTUnwrap(value as? [String: String])
    }

    private func placeholders(_ text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+0#]*(?:\d+)?(?:\.\d+)?(?:ll|l)?[@diufg]"#)
        let string = text as NSString
        return expression.matches(in: text.replacingOccurrences(of: "%%", with: "  "), range: NSRange(location: 0, length: string.length))
            .map { match in
                let token = string.substring(with: match.range)
                return token.replacingOccurrences(of: #"%\d+\$"#, with: "%", options: .regularExpression)
            }.sorted()
    }
}
