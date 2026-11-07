import XCTest
@testable import Egasu

final class DailyUsageAccumulatorTests: XCTestCase {
    func testDayKeyUsesInjectedCalendarAndZeroPads() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 2024-03-07 23:30 UTC — month·day 두 자리 zero pad 확인
        let date = calendar.date(from: DateComponents(year: 2024, month: 3, day: 7, hour: 23, minute: 30))!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: calendar), "2024-03-07")

        // key는 local-calendar 기준 — 동일 시점이 time zone에 따라 다른 날짜
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(DailyUsageAccumulator.dayKey(from: date, calendar: tokyo), "2024-03-08")
    }

    func testBuildSortsDaysNewestFirstAndSumsPerModel() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2024-06-01", tokens: 100, cost: 1.0, model: "sonnet")
        accumulator.add(day: "2024-06-03", tokens: 50, cost: 0.5, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 200, cost: 2.0, model: "sonnet")
        accumulator.add(day: "2024-06-01", tokens: 10, cost: 0.1, model: "opus")

        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.map(\.date), ["2024-06-03", "2024-06-01"])
        XCTAssertEqual(scan.series.daily.map(\.totalTokens), [50, 310])
        // 집계된 날은 항상 가격 산정 — 생략에 의한 nil 금지
        XCTAssertEqual(scan.series.daily[1].costUSD ?? -1, 3.1, accuracy: 0.0001)

        let june1 = scan.modelUsage?.daily.first { $0.date == "2024-06-01" }
        let models = Dictionary(uniqueKeysWithValues: (june1?.models ?? []).map { ($0.model, $0) })
        XCTAssertEqual(models["sonnet"]?.totalTokens, 300)
        XCTAssertEqual(models["sonnet"]?.costUSD ?? -1, 3.0, accuracy: 0.0001)
        XCTAssertEqual(models["opus"]?.totalTokens, 10)
    }

    func testUnknownModelMetadataAloneDoesNotCreateUsage() {
        var accumulator = DailyUsageAccumulator()
        accumulator.addUnknownModel(day: "2024-06-02", model: "mystery-model")

        let scan = accumulator.build()
        // 모델 이름만 추가해도 토큰·비용 이력을 만들지 않음.
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.unknownModelsByDay, ["2024-06-02": ["mystery-model"]])
    }

    func testMergedMetadataFailuresCannotBecomeAuthoritativeEmptyHistory() throws {
        let invalid = LogUsageScan(
            series: DailyUsageSeries(daily: []), unknownModelsByDay: [:], rejectedMetadataRows: 1
        )
        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([invalid, nil]))
        XCTAssertEqual(merged.rejectedMetadataRows, 1)
        XCTAssertNotNil(merged.metadataWarning)
        XCTAssertNil(merged.numericWarning)
        XCTAssertNil(merged.usageHistory)
    }

    func testUnpricedTokensKeepCostIncompleteAcrossNativeAndICloudMerges() throws {
        let now = Date()
        let day = DailyUsageAccumulator.dayKey(from: now)
        var native = DailyUsageAccumulator()
        native.add(day: day, tokens: 100, cost: 1, model: "priced")
        var shared = DailyUsageAccumulator()
        shared.add(day: day, tokens: 50, cost: nil, model: "unpriced")
        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([native.build(), shared.build()]))
        XCTAssertEqual(merged.series.daily.first?.totalTokens, 150)
        XCTAssertNil(merged.series.daily.first?.costUSD)
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.first { $0.model == "priced" }?.costUSD, 1)
        let synced = UsageHistoryAggregator.mergeHistories([
            try XCTUnwrap(native.build().usageHistory), try XCTUnwrap(shared.build().usageHistory)
        ], now: now)
        XCTAssertEqual(synced.series, merged.series)
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(merged.series, to: &lines, now: now, modelUsage: merged.modelUsage,
                                        modelSourceNote: "Fixture source")
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            guard case .values(_, let values, _, _, _, let breakdown) = line else {
                return XCTFail("Expected values line")
            }
            XCTAssertFalse(values.contains { $0.kind == .dollars })
            XCTAssertEqual(values.first { $0.kind == .count }?.number, 150)
            XCTAssertNil(breakdown?.totalCostUSD)
            XCTAssertEqual(breakdown?.models.first { $0.model == "priced" }?.costUSD, 1)
        }
    }

    func testZeroTokenUnknownCostDoesNotHidePricedUsageButReportedCostIsKept() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2026-11-01", tokens: 100, cost: 1, model: "priced")
        accumulator.add(day: "2026-11-01", tokens: 0, cost: nil, model: "unknown")

        let before = accumulator.build()
        XCTAssertEqual(before.series.daily, [DailyUsageEntry(date: "2026-11-01", totalTokens: 100, costUSD: 1)])
        XCTAssertFalse(before.modelUsage?.daily.first?.models.contains(where: { $0.model == "unknown" }) == true)

        accumulator.add(day: "2026-11-01", tokens: 0, cost: 0.25, model: "reported-cost")
        let after = accumulator.build()
        XCTAssertEqual(after.series.daily, [DailyUsageEntry(date: "2026-11-01", totalTokens: 100, costUSD: 1.25)])
        XCTAssertEqual(after.modelUsage?.daily.first?.models.first { $0.model == "reported-cost" }?.costUSD, 0.25)
    }

    func testUnpricedDayDoesNotBecomePartialThirtyDayCost() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(.init(daily: [
            .init(date: "2026-11-01", totalTokens: 100, costUSD: 1),
            .init(date: "2026-11-02", totalTokens: 50, costUSD: nil)
        ]), to: &lines)
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == "Last 30 Days" }) else {
            return XCTFail("Expected token-only period total")
        }
        XCTAssertEqual(values.map(\.kind), [.count])
        XCTAssertEqual(values.first?.number, 150)
    }

    func testMergeRetainsSeriesWhenSourceHasNoModelBreakdown() throws {
        let scan = LogUsageScan(series: .init(daily: [.init(date: "2026-11-01", totalTokens: 100, costUSD: nil)]),
                                unknownModelsByDay: [:])
        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([scan]))
        XCTAssertEqual(merged.series, scan.series)
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.first?.model, ModelUsageEntry.unattributedModelName)
    }
}
