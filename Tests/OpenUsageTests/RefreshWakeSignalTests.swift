import XCTest
@testable import OpenUsage

@MainActor
final class RefreshWakeSignalTests: XCTestCase {
    private let wakeName = Notification.Name("RefreshWakeSignalTests.wake")

    func testWakePostedBeforeWaitBeginsIsNotLost() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        center.post(name: wakeName, object: nil)

        let start = Date()
        await signal.waitForWake(timeout: 60)
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 5,
            "a wake posted before the wait began must be buffered, not lost"
        )
    }

    func testWakeWhileWaitingResumesBeforeTimeout() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        let start = Date()
        let wait = Task { await signal.waitForWake(timeout: 60) }
        // post 전에 대기를 suspend시켜 buffer가 아닌 live-wake 경로 검증
        await Task.yield()
        center.post(name: wakeName, object: nil)

        await wait.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testNoWakeFallsBackToTimeout() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        let start = Date()
        await signal.waitForWake(timeout: 0.1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.09)
    }

    func testWakeBurstCoalescesIntoASingleWake() async {
        let center = NotificationCenter()
        let signal = RefreshWakeSignal(name: wakeName, center: center)

        for _ in 0..<3 {
            center.post(name: wakeName, object: nil)
        }

        await signal.waitForWake(timeout: 60)

        let start = Date()
        await signal.waitForWake(timeout: 0.1)
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(start), 0.09,
            "a burst of wakes must coalesce into one, not queue up extra refresh passes"
        )
    }
}
