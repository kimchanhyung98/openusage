import XCTest
@testable import OpenUsage

/// 부하 높은 CI에서도 timer 경계를 넘도록 넉넉한 sleep 사용
@MainActor
final class TransientNoticeTests: XCTestCase {
    func testPresentBumpsTriggerAndAutoClears() async throws {
        let notice = TransientNotice<String?>(clearedValue: nil, timeout: .milliseconds(100))
        notice.present("Starred for menu bar")
        XCTAssertEqual(notice.value, "Starred for menu bar")
        XCTAssertEqual(notice.trigger, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(notice.value)
    }

    func testRePresentRestartsTheClearTimer() async throws {
        let notice = TransientNotice<String?>(clearedValue: nil, timeout: .milliseconds(800))
        notice.present("first")
        try await Task.sleep(for: .milliseconds(400))
        notice.present("second")
        // 누적 1000ms — 첫 timer 미취소였다면 이 지점에서 값이 지워짐
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(notice.value, "second")
        XCTAssertEqual(notice.trigger, 2)
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(notice.value)
    }

    func testClearResetsImmediatelyAndCancelsTheTimer() async throws {
        let notice = TransientNotice<Bool>(clearedValue: false, timeout: .milliseconds(100))
        notice.present(true)
        notice.clear()
        XCTAssertFalse(notice.value)
        XCTAssertEqual(notice.trigger, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(notice.value)
    }
}
