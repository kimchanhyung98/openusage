import XCTest
@testable import OpenUsage

final class SettingsFallbackTests: XCTestCase {
    func testTimeFormatDefaultsToTwentyFourHour() {
        XCTAssertEqual(TimeFormatSetting.fallback, .twentyFourHour)
    }
}
