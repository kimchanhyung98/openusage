import XCTest
@testable import OpenUsage

final class MeterSeverityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func percentData(used: Double, limit: Double? = 100,
                             displayMode: WidgetDisplayMode = .used) -> WidgetData {
        WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent,
                   used: used, limit: limit, displayMode: displayMode)
    }

    /// now 기준 일주일 window 중 `elapsed` 비율이 경과한 fixture
    private func pacedData(used: Double, elapsed: Double) -> WidgetData {
        var data = percentData(used: used)
        data.resetsAt = now.addingTimeInterval(week * (1 - elapsed))
        data.periodDurationMs = Int(week * 1000)
        return data
    }

    private func severity(_ data: WidgetData) -> WidgetData.MeterSeverity? {
        data.meterState(now: now).severity
    }

    // MARK: Pace-driven (a live reset window)

    func testBurningTooFastIsCriticalLongBeforeTheBarLooksFull() {
        // 66% 사용·1/3 경과 → 예상 ~182% — 절대 구간으로는 normal이지만 pace로는 red
        XCTAssertEqual(severity(pacedData(used: 66, elapsed: 0.363)), .critical)
    }

    func testCoastingToTheResetStaysNormalEvenWhenNearlyDrained() {
        // 85% 사용·96% 경과 → 예상 ~89% — 절대 구간 warning 대신 blue
        XCTAssertEqual(severity(pacedData(used: 85, elapsed: 0.96)), .normal)
    }

    func testProjectedIntoTheLastTenPercentIsWarning() {
        // 88% 사용·90% 경과 → 예상 ~97.8% → amber
        XCTAssertEqual(severity(pacedData(used: 88, elapsed: 0.9)), .warning)
    }

    func testLimitReachedIsSpentRegardlessOfElapsed() {
        XCTAssertEqual(pacedData(used: 100, elapsed: 0.5).meterState(now: now), .spent)
        XCTAssertEqual(pacedData(used: 130, elapsed: 0.02).meterState(now: now), .spent)
    }

    func testRemainderRoundingToZeroIsSpentOverACalmerPace() {
        // pace로는 amber지만 잔량 0.4%가 "0% left"로 반올림 — spent가 pace 판정보다 우선
        XCTAssertEqual(pacedData(used: 99.6, elapsed: 0.997).meterState(now: now), .spent)
    }

    func testRemainderRoundingToZeroIsSpentWithoutAResetWindow() {
        // reset/period 없음 — $0.004 잔량이 "$0.00"으로 반올림돼 spent
        let dollars = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                                 used: 99.996, limit: 100)
        XCTAssertEqual(dollars.meterState(now: now), .spent)
    }

    func testEarlyInWindowUsesPaceVerdictNotAbsoluteBands() {
        // window 초반에도 pace 판정 적용 — 2% 경과 시점의 과사용은 이미 초과 pace
        XCTAssertEqual(severity(pacedData(used: 50, elapsed: 0.02)), .critical)
        XCTAssertEqual(severity(pacedData(used: 85, elapsed: 0.02)), .critical)
    }

    // MARK: Absolute fallback (no reset window to project against)

    func testComfortableUsageIsNormal() {
        XCTAssertEqual(severity(percentData(used: 0)), .normal)
        XCTAssertEqual(severity(percentData(used: 50)), .normal)
        XCTAssertEqual(severity(percentData(used: 79)), .normal)
    }

    func testWarningStartsAtEightyPercentUsed() {
        XCTAssertEqual(severity(percentData(used: 80)), .warning)
        XCTAssertEqual(severity(percentData(used: 89)), .warning)
    }

    func testCriticalStartsAtTenPercentLeft() {
        XCTAssertEqual(severity(percentData(used: 90)), .critical)
        // limit 도달·초과는 spent (red bar)
        XCTAssertEqual(percentData(used: 100).meterState(now: now), .spent)
        XCTAssertEqual(percentData(used: 130).meterState(now: now), .spent)
    }

    func testThresholdsUseTheHeadlinesWholePercentRounding() {
        // headline이 "80% used"로 반올림되는 79.6%부터 yellow, 89.6%부터 red
        XCTAssertEqual(severity(percentData(used: 79.6)), .warning)
        XCTAssertEqual(severity(percentData(used: 89.4)), .warning)
        XCTAssertEqual(severity(percentData(used: 89.6)), .critical)
    }

    func testSeverityIgnoresTheUsedLeftDisplayMode() {
        // Left 모드에서 fill은 잔여분 표시지만 색상은 사용량 기준
        XCTAssertEqual(severity(percentData(used: 95, displayMode: .remaining)), .critical)
        XCTAssertEqual(severity(percentData(used: 85, displayMode: .remaining)), .warning)
        XCTAssertEqual(severity(percentData(used: 5, displayMode: .remaining)), .normal)
    }

    func testNonPercentKindsBandOnTheirShareOfTheLimit() {
        let dollars = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                                 used: 45, limit: 50)
        XCTAssertEqual(severity(dollars), .critical) // 잔액 $5 / $50 = 10%

        let counts = WidgetData(title: "Requests", icon: .providerMark("codex"), kind: .count,
                                used: 400, limit: 500, countSuffix: "requests")
        XCTAssertEqual(severity(counts), .warning) // 80% 사용
    }

    func testUnboundedAndZeroLimitMetricsStayNormal() {
        XCTAssertEqual(severity(percentData(used: 99, limit: nil)), .normal)
        XCTAssertEqual(severity(percentData(used: 99, limit: 0)), .normal)
    }

    func testNoDataHasNoSeverity() {
        var data = percentData(used: 50)
        data.hasData = false
        XCTAssertEqual(data.meterState(now: now), .noData)
        XCTAssertNil(severity(data))
    }
}
