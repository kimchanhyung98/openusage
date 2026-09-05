import XCTest
@testable import OpenUsage

final class SoftLimitMarkerTests: XCTestCase {
    func testMarkerOffsetCentersAndClampsInsideTrack() {
        XCTAssertEqual(
            MeterMarkerGeometry.offset(track: 100, fraction: 0.95, markerWidth: 1),
            94.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MeterMarkerGeometry.offset(track: 100, fraction: 0, markerWidth: 2),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MeterMarkerGeometry.offset(track: 100, fraction: 1, markerWidth: 2),
            98,
            accuracy: 0.0001
        )
    }

    func testMarkerMirrorsBetweenUsedAndLeft() {
        var data = WidgetData(
            title: "Weekly",
            icon: .providerMark("codex"),
            kind: .percent,
            used: 42,
            limit: 100
        )
        data.softLimitUsedFraction = 0.95

        XCTAssertEqual(data.softLimitMarkerFraction ?? -1, 0.95, accuracy: 0.0001)

        data.displayMode = .remaining
        XCTAssertEqual(data.softLimitMarkerFraction ?? -1, 0.05, accuracy: 0.0001)
    }

    func testMarkerRequiresBoundedData() {
        var noData = data(used: 42, softLimitUsedFraction: 0.95)
        noData.hasData = false
        XCTAssertNil(noData.softLimitMarkerFraction)

        var unbounded = WidgetData(
            title: "Weekly",
            icon: .providerMark("codex"),
            kind: .percent,
            used: 42
        )
        unbounded.softLimitUsedFraction = 0.95
        XCTAssertNil(unbounded.softLimitMarkerFraction)
    }

    func testMeterTooltipReportsGuideAndCrossing() {
        let below = data(used: 94, softLimitUsedFraction: 0.95)
        XCTAssertEqual(
            below.meterTooltip(for: below.meterState()),
            "Soft limit at 95% used"
        )
        XCTAssertEqual(below.softLimitStatusText, "Soft limit at 95% used")

        let reached = data(used: 95, softLimitUsedFraction: 0.95)
        XCTAssertEqual(
            reached.meterTooltip(for: reached.meterState()),
            "Soft limit reached at 95% used"
        )

        XCTAssertEqual(
            reached.meterTooltip(for: .spent),
            "Limit reached\nSoft limit reached at 95% used"
        )
    }

    func testReachedCopyUsesTheSameDisplayPrecisionAsTheHeadline() {
        let data = data(used: 94.6, softLimitUsedFraction: 0.95)

        XCTAssertEqual(data.headline, "95% used")
        XCTAssertEqual(data.softLimitStatusText, "Soft limit reached at 95% used")
    }

    func testPercentBoundaryIsStableAcrossDisplayModes() {
        for (used, reached) in [(94.49, false), (94.5, true), (94.6, true), (95.0, true)] {
            var data = data(used: used, softLimitUsedFraction: 0.95)
            let expected = reached ? "Soft limit reached at 95% used" : "Soft limit at 95% used"
            XCTAssertEqual(data.softLimitStatusText, expected, "Used: \(used)")
            data.displayMode = .remaining
            XCTAssertEqual(data.softLimitStatusText, expected, "Left: \(used)")
        }
    }

    func testDollarBoundaryUsesCentPrecision() {
        for (used, reached) in [(94.994, false), (94.996, true), (95.0, true)] {
            var data = WidgetData(
                title: "Weekly",
                icon: .providerMark("opencode"),
                kind: .dollars,
                used: used,
                limit: 100
            )
            data.softLimitUsedFraction = 0.95
            let expected = reached ? "Soft limit reached at 95% used" : "Soft limit at 95% used"
            XCTAssertEqual(data.softLimitStatusText, expected, "Used: \(used)")
            data.displayMode = .remaining
            XCTAssertEqual(data.softLimitStatusText, expected, "Left: \(used)")
        }
    }

    private func data(used: Double, softLimitUsedFraction: Double?) -> WidgetData {
        var data = WidgetData(
            title: "Weekly",
            icon: .providerMark("codex"),
            kind: .percent,
            used: used,
            limit: 100
        )
        data.softLimitUsedFraction = softLimitUsedFraction
        return data
    }
}
