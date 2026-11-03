import XCTest
@testable import Egasu

final class SettingsFallbackTests: XCTestCase {
    func testTimeFormatDefaultsToTwentyFourHour() {
        XCTAssertEqual(TimeFormatSetting.fallback, .twentyFourHour)
    }
}
