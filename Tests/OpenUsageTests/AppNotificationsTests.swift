import XCTest
import UserNotifications
@testable import OpenUsage

/// 시스템 center 접근 차단과 주입된 권한·예약·제거 경계에서 계정 교체 검증.
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

    func testAccountChangeDuringAuthorizationPreventsSubmission() async throws {
        let request = notificationRequest()
        var current = true
        var submitted: [String] = []
        var removed: [String] = []
        let delivered = try await AppNotifications.deliver(
            request,
            isCurrent: { current },
            authorize: { current = false; return true },
            add: { submitted.append($0.identifier) },
            remove: { removed.append($0) }
        )
        XCTAssertFalse(delivered)
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(removed.isEmpty)
    }

    func testAccountChangeDuringSubmissionRemovesOnlyThatRequest() async throws {
        let request = notificationRequest()
        var current = true
        var submitted: [String] = []
        var removed: [String] = []
        let delivered = try await AppNotifications.deliver(
            request,
            isCurrent: { current },
            authorize: { true },
            add: {
                submitted.append($0.identifier)
                current = false
            },
            remove: { removed.append($0) }
        )
        XCTAssertFalse(delivered)
        XCTAssertEqual(submitted, [request.identifier])
        XCTAssertEqual(removed, [request.identifier])
    }

    func testCurrentAccountDeliveryIsKeptAndDeniedAuthorizationDoesNotSubmit() async throws {
        for authorized in [true, false] {
            let request = notificationRequest()
            var submitted: [String] = []
            var removed: [String] = []
            let delivered = try await AppNotifications.deliver(
                request,
                isCurrent: { true },
                authorize: { authorized },
                add: { submitted.append($0.identifier) },
                remove: { removed.append($0) }
            )
            XCTAssertEqual(delivered, authorized)
            XCTAssertEqual(submitted, authorized ? [request.identifier] : [])
            XCTAssertTrue(removed.isEmpty)
        }
    }

    private func notificationRequest() -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
    }

    /// `@Sendable` provider closure의 실행 여부 기록용 참조 box
    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }
}
