import XCTest
@testable import OpenUsage

final class WidgetZeroUsageTests: XCTestCase {
    private func row(values: [MetricValue], hasData: Bool = true) -> WidgetData {
        WidgetData(title: "Today", icon: .providerMark("codex"), kind: .count, used: 0, limit: nil,
                   hasData: hasData, values: values)
    }

    func testAllZeroValuesAreZeroUsage() {
        let data = row(values: [MetricValue(number: 0, kind: .dollars),
                                MetricValue(number: 0, kind: .count)])
        XCTAssertTrue(data.isZeroUsage)
    }

    func testSmallNonZeroValuesAreNotZeroUsage() {
        let data = row(values: [MetricValue(number: 5, kind: .dollars),
                                MetricValue(number: 200, kind: .count)])
        XCTAssertFalse(data.isZeroUsage)
    }

    func testNoDataIsNotZeroUsage() {
        let data = row(values: [MetricValue(number: 0, kind: .count)], hasData: false)
        XCTAssertFalse(data.isZeroUsage)
    }

    func testEmptyValuesAreNotZeroUsage() {
        XCTAssertFalse(row(values: []).isZeroUsage)
    }
}
