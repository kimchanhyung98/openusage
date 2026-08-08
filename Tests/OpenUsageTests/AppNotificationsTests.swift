import XCTest
import UserNotifications
@testable import OpenUsage

/// `UNUserNotificationCenter`는 단위 테스트에서 생성·상속 불가 — XCTest 하의 short-circuit만 검증
@MainActor
final class AppNotificationsTests: XCTestCase {
    func testIsRunningUnderTestsIsTrueInTheHarness() {
        XCTAssertTrue(AppNotifications.isRunningUnderTests)
    }

    func testShowHandlerIsInvokedByShow() {
        var opened = false
        MenuBarPopover.showHandler = { opened = true }
        defer { MenuBarPopover.showHandler = nil }
        MenuBarPopover.show()
        XCTAssertTrue(opened)
    }

    func testPostIsANoOpUnderTestsAndNeverTouchesTheCenter() async {
        let probe = CenterProbe()
        let notifications = AppNotifications(centerProvider: {
            probe.touched = true
            return UNUserNotificationCenter.current()
        })
        _ = await notifications.post(idPrefix: "claude.session.healthyToClose", title: "Cutting It Close", subtitle: "Claude Session", body: "x")
        notifications.registerAsDelegate()
        XCTAssertFalse(probe.touched, "Under tests, no notification path should reach the center provider")
    }

    /// `@Sendable` provider closure의 실행 여부 기록용 참조 box
    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }
}
