import XCTest
@testable import OpenUsage

final class SettingsLocalizationTests: XCTestCase {
    func testDisplayLabelsFollowLanguageWithoutChangingStoredValues() {
        L10n.withLanguage(.korean) {
            XCTAssertEqual(AppearanceSetting.system.label, "시스템 설정")
            XCTAssertEqual(DensitySetting.compact.label, "좁게")
            XCTAssertEqual(TimeFormatSetting.twentyFourHour.label, "24시간")
            XCTAssertEqual(LogLevelSetting.warn.label, "경고")
            XCTAssertEqual(MenuBarStyle.bars.label, "막대")
            XCTAssertEqual(WidgetDisplayMode.remaining.label, "남음")
            XCTAssertEqual(ResetDisplayMode.relative.label, "남은 시간")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(AppearanceSetting.system.label, "システム設定")
            XCTAssertEqual(DensitySetting.compact.label, "コンパクト")
            XCTAssertEqual(TimeFormatSetting.twentyFourHour.label, "24時間")
            XCTAssertEqual(LogLevelSetting.warn.label, "警告")
            XCTAssertEqual(MenuBarStyle.bars.label, "バー")
            XCTAssertEqual(WidgetDisplayMode.remaining.label, "残り")
            XCTAssertEqual(ResetDisplayMode.relative.label, "残り時間")
        }
        XCTAssertEqual(AppearanceSetting.system.rawValue, "system")
        XCTAssertEqual(DensitySetting.compact.rawValue, "compact")
        XCTAssertEqual(TimeFormatSetting.twentyFourHour.rawValue, "24h")
        XCTAssertEqual(LogLevelSetting.warn.rawValue, "warn")
        XCTAssertEqual(MenuBarStyle.bars.rawValue, "bars")
        XCTAssertEqual(WidgetDisplayMode.remaining.rawValue, "remaining")
        XCTAssertEqual(ResetDisplayMode.relative.rawValue, "relative")
    }

    func testThresholdMessageFormatsTheAppliedPercentage() {
        let key = "Enter a whole number from 1 to 100. %d%% is still applied."
        L10n.withLanguage(.english) {
            XCTAssertEqual(L10n.settings(key, 95), "Enter a whole number from 1 to 100. 95% is still applied.")
        }
        L10n.withLanguage(.korean) {
            XCTAssertEqual(L10n.settings(key, 95), "1부터 100까지의 정수를 입력하세요. 현재 95%가 적용 중입니다.")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(L10n.settings(key, 95), "1から100までの整数を入力してください。現在は95%が適用されています。")
        }
    }

    func testSettingsFormatStringsPreserveUserProvidedValues() {
        let path = "/Users/테스트 user/bin/openusage"
        L10n.withLanguage(.korean) {
            XCTAssertEqual(
                L10n.settings("%@ already exists and wasn't installed by OpenUsage.", path),
                "\(path) 경로가 이미 있으며, OpenUsage가 설치한 항목이 아닙니다."
            )
            XCTAssertEqual(L10n.settings("%d/%d bytes", 12, 64), "12/64바이트")
            XCTAssertEqual(L10n.settings("%dm ago", 3), "3분 전")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(L10n.settings("%d/%d bytes", 12, 64), "12/64バイト")
            XCTAssertEqual(L10n.settings("%dm ago", 3), "3分前")
        }
    }
}
