import XCTest
@testable import OpenUsage

final class MenuBarBarsTests: XCTestCase {
    func testZeroOrNegativeFractionDrawsNothing() {
        XCTAssertEqual(MenuBarBarGeometry.fill(trackW: 100, fraction: 0).fillW, 0)
        XCTAssertEqual(MenuBarBarGeometry.fill(trackW: 100, fraction: -0.5).fillW, 0)
    }

    func testFullFractionFillsTrackWithNoRemainder() {
        let fill = MenuBarBarGeometry.fill(trackW: 100, fraction: 1)
        XCTAssertEqual(fill.fillW, 100)
        XCTAssertEqual(fill.remainderW, 0)
        XCTAssertNil(fill.dividerX)
    }

    func testNearFullKeepsAVisibleTail() {
        // 0.97은 track을 다 채우지 않음 — quantization + 최소 가시 remainder로 꼬리 유지
        let fill = MenuBarBarGeometry.fill(trackW: 100, fraction: 0.97)
        XCTAssertLessThan(fill.fillW, 100)
        XCTAssertGreaterThanOrEqual(fill.remainderW, 20)   // 계산: minVisible = max(4, 100 * 0.2)
        XCTAssertEqual(fill.dividerX, fill.fillW)
    }

    func testMidFractionIsNotQuantized() {
        XCTAssertEqual(MenuBarBarGeometry.visualFraction(0.5), 0.5, accuracy: 0.0001)
    }

    func testVisualFractionQuantizesNearFullInFifteenPercentSteps() {
        // 계산: 0.97 → remainder 0.03 → ceil(0.03 / 0.15) * 0.15 = 0.15 → visual 0.85
        XCTAssertEqual(MenuBarBarGeometry.visualFraction(0.97), 0.85, accuracy: 0.0001)
        // 1.0은 full, 0.0은 empty 유지
        XCTAssertEqual(MenuBarBarGeometry.visualFraction(1), 1, accuracy: 0.0001)
        XCTAssertEqual(MenuBarBarGeometry.visualFraction(0), 0, accuracy: 0.0001)
    }
}
