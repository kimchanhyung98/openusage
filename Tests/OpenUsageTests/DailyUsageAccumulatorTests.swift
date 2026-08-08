import XCTest
@testable import OpenUsage

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

    func testUnknownModelsStayOutOfTheSeries() {
        var accumulator = DailyUsageAccumulator()
        accumulator.addUnknownModel(day: "2024-06-02", model: "mystery-model")

        let scan = accumulator.build()
        // 가격 산정 불가 usage만 있는 날은 series·model breakdown 미포함 — warning triangle로만 노출
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.modelUsage?.daily.isEmpty, true)
        XCTAssertEqual(scan.unknownModelsByDay, ["2024-06-02": ["mystery-model"]])
    }
}
