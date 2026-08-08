import XCTest
@testable import OpenUsage

final class OpenCodeLayoutTests: XCTestCase {
    private let aboveFold = ["opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend"]
    private let belowCaret = ["opencode.today", "opencode.yesterday", "opencode.last30"]

    func testAllMetricsEnabledByDefault() {
        for id in aboveFold + belowCaret {
            XCTAssertTrue(DefaultLayout.metricIDs.contains(id), "\(id) should be enabled by default")
        }
    }

    func testCapsAndTrendStayAboveTheFold() {
        for id in aboveFold {
            XCTAssertFalse(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should stay above the fold")
        }
    }

    func testSpendTilesSitBelowTheCaret() {
        for id in belowCaret {
            XCTAssertTrue(DefaultLayout.expandedMetricIDs.contains(id), "\(id) should sit below the caret")
        }
    }

    func testNothingPinnedByDefault() {
        XCTAssertFalse(
            DefaultLayout.pinnedMetricIDs.contains { $0.hasPrefix("opencode.") },
            "a freshly auto-enabled provider adds no menu-bar pins (matches Grok/Devin)"
        )
    }
}
