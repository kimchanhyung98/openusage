import XCTest
@testable import OpenUsage

@MainActor
final class LaunchAtLoginSettingTests: XCTestCase {
    func testFailedChangeRollsBackWithoutMakingASecondSystemCall() {
        let systemEnabled = false
        var requestedValues: [Bool] = []
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                requestedValues.append(enabled)
                throw TestError.rejected
            }
        )

        setting.update(to: true)

        XCTAssertEqual(requestedValues, [true])
        XCTAssertFalse(setting.isEnabled)
        XCTAssertEqual(setting.errorMessage, LaunchAtLoginSetting.failureMessage)
    }

    func testLaterSuccessUpdatesTheSwitchAndClearsTheError() {
        var systemEnabled = false
        var shouldFail = true
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                if shouldFail { throw TestError.rejected }
                systemEnabled = enabled
            }
        )
        setting.update(to: true)
        shouldFail = false

        setting.update(to: true)

        XCTAssertTrue(setting.isEnabled)
        XCTAssertNil(setting.errorMessage)
    }

    func testFailureMessageUsesEachScopedLanguageWhenTheErrorOccurs() {
        let setting = LaunchAtLoginSetting(
            currentStatus: { false },
            setEnabled: { _ in throw TestError.rejected }
        )
        let expected: [(LanguageSetting, String)] = [
            (.english, "macOS wouldn't update Launch at Login. Check System Settings → Login Items."),
            (.korean, "macOS에서 로그인 시 실행 설정을 변경하지 못했습니다. 시스템 설정 → 로그인 항목을 확인하세요."),
            (.japanese, "macOSでログイン時の起動設定を変更できませんでした。システム設定 → ログイン項目を確認してください。")
        ]

        for (language, message) in expected {
            L10n.withLanguage(language) {
                setting.update(to: true)
                XCTAssertEqual(setting.errorMessage, message)
            }
        }
    }

    private enum TestError: Error {
        case rejected
    }
}
