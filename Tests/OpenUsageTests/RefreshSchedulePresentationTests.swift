import XCTest
@testable import OpenUsage

final class RefreshSchedulePresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSingleCountdownKeepsPreviousCopyAndRounding() {
        for (interval, expected) in [
            (300.0, "Next update in 5m"),
            (60.1, "Next update in 2m"),
            (60.0, "Next update in 1m"),
            (59.1, "Next update in 1m"),
            (59.0, "Next update in 59s"),
            (0.1, "Next update in 1s"),
            (-1.0, "Next update in 0s"),
        ] {
            XCTAssertEqual(RefreshSchedulePresentation.statusText(
                isUpdating: false, nextRefreshAt: now.addingTimeInterval(interval), now: now
            ), expected)
        }
    }

    func testUpdatingReplacesCountdownAndManualRefreshLabel() {
        for date: Date? in [now.addingTimeInterval(300), nil] {
            XCTAssertEqual(RefreshSchedulePresentation.statusText(
                isUpdating: true, nextRefreshAt: date, now: now
            ), "Updating…")
        }
    }

    func testUnscheduledRefreshKeepsManualRefreshAvailable() {
        XCTAssertEqual(RefreshSchedulePresentation.statusText(
            isUpdating: false, nextRefreshAt: nil, now: now
        ), "Refresh Now")
    }
}
