import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarContentTests: XCTestCase {
    func testEmptyWhenNoGroups() {
        let content = MenuBarContentBuilder.build(groups: [], data: { $0.sample })
        XCTAssertTrue(content.isEmpty)
        XCTAssertTrue(content.bars.isEmpty)
    }

    func testTextGroupsPreserveOrderLabelsAndValues() {
        let m1 = percent("a.m1", "Session", 97)
        let m2 = percent("a.m2", "Weekly", 12)
        let b1 = percent("b.m1", "Total", 50)
        let content = MenuBarContentBuilder.build(groups: [group("a", m1, m2), group("b", b1)], data: { $0.sample })

        XCTAssertEqual(content.groups.map(\.providerID), ["a", "b"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.m1", "a.m2"])
        XCTAssertEqual(content.groups[0].metrics[0].label, "Session")
        XCTAssertEqual(content.groups[0].metrics[0].value, m1.sample.valueText)
        XCTAssertEqual(content.groups[1].metrics.map(\.id), ["b.m1"])
    }

    func testBarsIncludeBoundedMetricsAndDropUnbounded() {
        // bounded dollar metric은 fill이 있어 Bars 포함, unbounded(limit 없는 raw spend)는 제외
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                percent("a.pct", "Pct", 40),
                boundedDollars("a.credits", "Credits", used: 12000, limit: 18000),
                unbounded("a.spend", "Spend"))],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.pct", "a.credits", "a.spend"])  // Text: 전체
        XCTAssertEqual(content.bars.map(\.id), ["a.pct", "a.credits"])                          // Bars: bounded만
    }

    func testBarsCappedToFourInOrder() {
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.m1", "M1", 10), percent("a.m2", "M2", 20)),
                group("b", percent("b.m1", "M1", 30), percent("b.m2", "M2", 40)),
                group("c", percent("c.m1", "M1", 50), percent("c.m2", "M2", 60))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.bars.count, 4)
        XCTAssertEqual(content.bars.map(\.id), ["a.m1", "a.m2", "b.m1", "b.m2"])
    }

    func testNoDataMetricsDropFromStrip() {
        // data 없는 pinned metric은 "—" 대신 제거 — pin 전부가 data 없는 provider는 icon도 미기여
        let content = MenuBarContentBuilder.build(
            groups: [
                group("a", percent("a.live", "Session", 41), noDataPercent("a.dark", "Weekly")),
                group("b", noDataPercent("b.nd", "ND"))
            ],
            data: { $0.sample }
        )

        XCTAssertEqual(content.groups.map(\.providerID), ["a"])
        XCTAssertEqual(content.groups[0].metrics.map(\.id), ["a.live"])
        XCTAssertEqual(content.bars.map(\.id), ["a.live"])
    }

    func testAllPinsWithoutDataFallBackToAppIcon() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", noDataPercent("a.nd", "ND"))],
            data: { $0.sample }
        )
        XCTAssertTrue(content.isEmpty)
    }

    func testAccessibilityTextSummarizesGroups() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41), percent("a.m2", "Weekly", 12))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.accessibilityText, "A Session 41%, Weekly 12%")
    }

    func testAccessibilityTextUsesTheResolvedTitle() {
        // VoiceOver 요약은 baked provider 이름 대신 caller의 resolver(account registry) 이름 사용
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.m1", "Session", 41))],
            data: { $0.sample },
            title: { _ in "Claude Team" }
        )
        XCTAssertEqual(content.accessibilityText, "Claude Team Session 41%")
    }

    func testTrayLabelsShortenLongTimeWindows() {
        let content = MenuBarContentBuilder.build(
            groups: [group("a", percent("a.today", "Today", 5), percent("a.month", "Last 30 Days", 80))],
            data: { $0.sample }
        )
        XCTAssertEqual(content.groups[0].metrics.map(\.label), ["T", "M"])
    }

    func testBoundedTrayValuesStayUnitAware() {
        // percent는 %, bounded dollars/counts는 고유 단위 유지 — "used / limit" %로 붕괴 금지
        let usage = percent("a.usage", "Usage", 67)
        let credits = boundedDollars("a.credits", "Credits", used: 12000, limit: 18000)
        let requests = boundedCount("a.requests", "Requests", used: 412, limit: 500)
        let spend = unbounded("a.spend", "Spend")
        let content = MenuBarContentBuilder.build(groups: [group("a", usage, credits, requests, spend)], data: { $0.sample })

        XCTAssertEqual(content.groups[0].metrics.map(\.value), ["67%", "$12K", "412", "$42"])
    }

    func testUnboundedNumbersAreCompacted() {
        // 큰 수는 표준 compact 표기, 전체 표시 값은 소수점 제거
        let content = MenuBarContentBuilder.build(
            groups: [group("a",
                unbounded("a.big", "Big", 12923),
                unbounded("a.small", "Small", 129.81))],
            data: { $0.sample }
        )

        let big = content.groups[0].metrics[0].value
        XCTAssertTrue(big.hasSuffix("K"), "expected compact thousands, got \(big)")
        XCTAssertFalse(big.contains("923"), "expected the raw number to be compacted away, got \(big)")
        XCTAssertEqual(content.groups[0].metrics[1].value, "$130")
    }

    // MARK: - Fixtures

    private func group(_ providerID: String, _ metrics: WidgetDescriptor...) -> ProviderMetrics {
        let provider = Provider(
            id: providerID,
            displayName: providerID.uppercased(),
            icon: .providerMark("cursor")
        )
        return ProviderMetrics(provider: provider, metrics: metrics)
    }

    private func percent(_ id: String, _ label: String, _ used: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: used, limit: 100))
    }

    private func boundedDollars(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: limit))
    }

    private func boundedCount(_ id: String, _ label: String, used: Double, limit: Double) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .count, used: used, limit: limit))
    }

    private func unbounded(_ id: String, _ label: String, _ used: Double = 42) -> WidgetDescriptor {
        descriptor(id, label, WidgetData(title: label, icon: .providerMark("cursor"), kind: .dollars, used: used, limit: nil))
    }

    private func noDataPercent(_ id: String, _ label: String) -> WidgetDescriptor {
        var sample = WidgetData(title: label, icon: .providerMark("cursor"), kind: .percent, used: 0, limit: 100)
        sample.hasData = false
        return descriptor(id, label, sample)
    }

    private func descriptor(_ id: String, _ label: String, _ sample: WidgetData) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: String(id.prefix { $0 != "." }),
            metricLabel: label,
            sample: sample
        )
    }
}
