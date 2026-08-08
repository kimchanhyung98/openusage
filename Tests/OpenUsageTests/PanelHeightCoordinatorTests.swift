import XCTest
@testable import OpenUsage

@MainActor
final class PanelHeightCoordinatorTests: XCTestCase {
    private let topBar: CGFloat = 44

    func testDashboardIdealOmitsTopBar() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .dashboard)
        c.setFooter(40, for: .dashboard)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 340)
    }

    func testOtherScreensIncludeTopBar() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .customize)
        c.setFooter(40, for: .customize)
        XCTAssertEqual(c.measuredIdeal[.customize], 44 + 40 + 300)
    }

    func testFooterDefaultsToZeroUntilMeasured() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .settings)
        XCTAssertEqual(c.measuredIdeal[.settings], 44 + 300)
    }

    func testIdealUnsetUntilScrollContentMeasured() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setFooter(40, for: .dashboard)
        XCTAssertNil(c.measuredIdeal[.dashboard])
        c.setScrollContent(0, for: .dashboard)
        XCTAssertNil(c.measuredIdeal[.dashboard])
    }

    func testTargetIsNilUntilMeasuredThenClamps() {
        // clamp hook은 process 전역 — suite 순서 의존을 피하려 양쪽 분기에서 명시 고정
        let previousClamp = MenuBarPopover.clampHeight
        defer { MenuBarPopover.clampHeight = previousClamp }

        let c = PanelHeightCoordinator(topBarHeight: topBar)
        XCTAssertNil(c.target(for: .dashboard))

        MenuBarPopover.clampHeight = nil
        c.setScrollContent(300, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 300)

        MenuBarPopover.clampHeight = { min(max($0, 400), 600) }
        XCTAssertEqual(c.target(for: .dashboard), 400)
        c.setScrollContent(900, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 600)
        c.setScrollContent(500, for: .dashboard)
        XCTAssertEqual(c.target(for: .dashboard), 500)
    }

    func testLaterMeasurementRecomposesIdeal() {
        let c = PanelHeightCoordinator(topBarHeight: topBar)
        c.setScrollContent(300, for: .dashboard)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 300)
        c.setScrollContent(500, for: .dashboard)
        XCTAssertEqual(c.measuredIdeal[.dashboard], 500)
    }
}
