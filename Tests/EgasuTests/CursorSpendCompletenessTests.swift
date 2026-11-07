import XCTest
@testable import Egasu

final class CursorSpendCompletenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnpricedVariantPreservesFamilyTokensAndKnownVariantCostInEitherOrder() throws {
        let rows = [
            row(model: "gpt-5.5", tokens: 100, cost: 1),
            row(model: "gpt-5.5-extra-high-fast", tokens: 200, cost: nil),
            row(model: "gpt-5.5-extra-high-fast", tokens: 300, cost: 3)
        ]

        for orderedRows in [rows, Array(rows.reversed())] {
            var lines: [MetricLine] = []
            let history = CursorUsageMapper.appendSpendLines(
                rows: orderedRows, now: now, pricing: TestPricing.bundled, to: &lines
            )

            let family = try XCTUnwrap(history.modelUsage?.daily.first?.models.first)
            XCTAssertEqual(family.model, "gpt-5.5")
            XCTAssertEqual(family.totalTokens, 600)
            XCTAssertNil(family.costUSD)
            let variants = try XCTUnwrap(family.variants)
            let priced = try XCTUnwrap(variants.first { $0.model == "gpt-5.5" })
            XCTAssertEqual(priced.totalTokens, 100)
            XCTAssertEqual(priced.costUSD, 1)
            let incomplete = try XCTUnwrap(variants.first { $0.model == "gpt-5.5-extra-high-fast" })
            XCTAssertEqual(incomplete.totalTokens, 500)
            XCTAssertNil(incomplete.costUSD)
            XCTAssertNil(try XCTUnwrap(history.series.daily.first).costUSD)
        }
    }

    func testUnpricedEarlierDayMakesPeriodCostIncompleteWithoutChangingTodaysCost() throws {
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let rows = [
            row(model: "composer-1", tokens: 100, cost: 1),
            row(model: "composer-1", tokens: 200, cost: nil, date: yesterday)
        ]
        var lines: [MetricLine] = []
        CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let snapshot = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: lines)

        let today = TotalSpendAggregator.total(for: .today, providers: [provider], snapshots: [provider.id: snapshot])
        XCTAssertEqual(today.totalTokens, 100)
        XCTAssertEqual(today.totalUSD, 1)
        XCTAssertFalse(today.projection(for: .costPerMtok).isEmpty)
        let period = TotalSpendAggregator.total(for: .last30, providers: [provider], snapshots: [provider.id: snapshot])
        XCTAssertEqual(period.totalTokens, 300)
        XCTAssertTrue(period.projection(for: .cost).isEmpty)
        XCTAssertTrue(period.projection(for: .costPerMtok).isEmpty)
        XCTAssertEqual(period.projection(for: .tokens).centerValue, 300)
        guard case .values(_, _, _, _, _, let optionalBreakdown) = lines.first(where: { $0.label == "Last 30 Days" }) else {
            return XCTFail("expected the period usage line")
        }
        let breakdown = try XCTUnwrap(optionalBreakdown)
        XCTAssertEqual(breakdown.models.count, 1)
        XCTAssertEqual(breakdown.models.first?.totalTokens, 300)
        XCTAssertNil(breakdown.models.first?.costUSD)
    }

    private func row(model: String, tokens: Int, cost: Double?, date: Date? = nil) -> CursorUsageCSVRow {
        CursorUsageCSVRow(
            date: date ?? now, model: model, tokens: TokenBreakdown(input: tokens), imputedCostDollars: cost
        )
    }
}
