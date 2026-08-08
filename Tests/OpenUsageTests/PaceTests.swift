import XCTest
@testable import OpenUsage

final class PaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    /// `now` 기준으로 window의 `elapsed` 비율만큼 경과한 reset 시각
    private func resetsAt(elapsed: Double, period: TimeInterval) -> Date {
        now.addingTimeInterval(period * (1 - elapsed))
    }

    func testZeroUsageIsAhead() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.evaluate(used: 0, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .ahead)
    }

    func testAtOrOverLimitIsBehind() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.evaluate(used: 100, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .behind)
        XCTAssertEqual(Pace.evaluate(used: 130, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .behind)
    }

    func testEarlyInWindowStillProjectsPace() {
        let reset = resetsAt(elapsed: 0.02, period: week)
        XCTAssertEqual(Pace.evaluate(used: 5, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .behind)
    }

    func testAheadOnTrackBehindThresholds() {
        let reset = resetsAt(elapsed: 0.5, period: week) // window 절반 경과 → 예상치 = used * 2
        XCTAssertEqual(Pace.evaluate(used: 30, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .ahead)   // 계산: 60 ≤ 90
        XCTAssertEqual(Pace.evaluate(used: 44, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .ahead)   // 계산: 88 ≤ 90
        XCTAssertEqual(Pace.evaluate(used: 46, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .onTrack) // 92는 (90,100] 구간
        XCTAssertEqual(Pace.evaluate(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .onTrack) // 100은 limit과 정확히 일치
        XCTAssertEqual(Pace.evaluate(used: 60, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .behind)  // 계산: 120 > 100
    }

    func testEvaluateProjectsEndOfPeriodUsage() {
        let reset = resetsAt(elapsed: 0.5, period: week) // 절반 경과 → 예상치 = used * 2
        let result = Pace.evaluate(used: 30, limit: 100, resetsAt: reset, periodDuration: week, now: now)
        XCTAssertEqual(result?.status, .ahead)
        XCTAssertEqual(result?.projectedUsage ?? 0, 60, accuracy: 0.01)
    }

    func testWindowAlreadyResetReturnsNil() {
        let past = now.addingTimeInterval(-60)
        XCTAssertNil(Pace.evaluate(used: 50, limit: 100, resetsAt: past, periodDuration: week, now: now))
        // 경계: resetsAt == now는 live window가 아니라 이미 reset
        XCTAssertNil(Pace.evaluate(used: 50, limit: 100, resetsAt: now, periodDuration: week, now: now))
    }

    // MARK: MeterState (the view-facing projection of the pace verdict)

    /// window 절반 경과 상태 — 예상치 = used * 2
    private func weeklyData(used: Double, displayMode: WidgetDisplayMode = .used) -> WidgetData {
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent,
                              used: used, limit: 100, displayMode: displayMode)
        data.resetsAt = resetsAt(elapsed: 0.5, period: week)
        data.periodDurationMs = Int(week * 1000)
        return data
    }

    private func tick(_ data: WidgetData) -> Double? {
        let state = data.meterState(now: now)
        return data.paceTick(for: state, now: now)
    }

    private func spare(_ data: WidgetData) -> String? {
        if case .closeToLimit(let spare, _) = data.meterState(now: now) { return spare }
        return nil
    }

    func testEvenPaceTickOnAmberAndRedInBothDisplayModes() {
        // window 절반 경과 → Used·Left 양쪽 모두 even-pace tick 0.5
        XCTAssertEqual(tick(weeklyData(used: 46)) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(tick(weeklyData(used: 46, displayMode: .remaining)) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(tick(weeklyData(used: 60)) ?? 0, 0.5, accuracy: 0.001)
        XCTAssertNil(tick(weeklyData(used: 30))) // ahead 상태는 기본적으로 tick 숨김
    }

    func testNoTickWithoutAResetWindow() {
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                              used: 12, limit: 20)
        XCTAssertNil(tick(data))
        data.resetsAt = now.addingTimeInterval(week)
        XCTAssertNil(tick(data))
    }

    func testTooltipShowsNumericProjectionAtReset() {
        XCTAssertEqual(weeklyData(used: 30).meterState(now: now).tooltip, "~40% left at reset")
        XCTAssertEqual(weeklyData(used: 46).meterState(now: now).tooltip, "~92% used at reset")
        XCTAssertEqual(weeklyData(used: 60).meterState(now: now).tooltip, "~20% over limit at reset")
    }

    func testTooltipBlueCushionAtZeroUsage() {
        XCTAssertEqual(weeklyData(used: 0).meterState(now: now).tooltip, "~100% left at reset")
    }

    func testTooltipRedOverageFlooredToOnePercent() {
        XCTAssertEqual(weeklyData(used: 50.2).meterState(now: now).tooltip, "~1% over limit at reset")
    }

    func testSpentReadsLimitReached() {
        XCTAssertEqual(weeklyData(used: 100).meterState(now: now), .spent)
        XCTAssertEqual(weeklyData(used: 100).meterState(now: now).tooltip, "Limit reached")
        let nearlyEmpty = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                                     used: 99.999, limit: 100)
        XCTAssertEqual(nearlyEmpty.meterState(now: now), .spent)
        let withHeadroom = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                                      used: 99.0, limit: 100)
        XCTAssertNil(withHeadroom.meterState(now: now).tooltip)
    }

    func testSpareCopyOnlyWhenAmber() {
        XCTAssertEqual(spare(weeklyData(used: 46)), "~8% spare")
        XCTAssertNil(spare(weeklyData(used: 30)))
        XCTAssertNil(spare(weeklyData(used: 60)))
    }

    func testSpentOutranksCloseToLimitSoNoTickOrSpare() {
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent,
                              used: 99.6, limit: 100)
        data.resetsAt = resetsAt(elapsed: 0.997, period: week)
        data.periodDurationMs = Int(week * 1000)
        XCTAssertEqual(data.meterState(now: now), .spent)
        XCTAssertNil(tick(data))
        XCTAssertNil(spare(data))
    }

    func testProjectedToLandAtTheLimitPromotesToRed() {
        let data = weeklyData(used: 49.8)
        guard case .runningOut(let eta, _) = data.meterState(now: now) else {
            return XCTFail("expected runningOut")
        }
        XCTAssertNil(eta)
        XCTAssertNotNil(tick(data))
        XCTAssertNil(spare(data))
        XCTAssertEqual(data.meterState(now: now).tooltip, "~100% used at reset")
    }

    func testProjectedExactlyAtLimitIsRedNotAmber() {
        let reset = resetsAt(elapsed: 0.5, period: week)
        XCTAssertEqual(Pace.evaluate(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now)?.status, .onTrack)
        guard case .runningOut(let eta, _) = weeklyData(used: 50).meterState(now: now) else {
            return XCTFail("expected runningOut")
        }
        XCTAssertNil(eta)
    }

    func testSmallButRealCushionStaysAmber() {
        XCTAssertEqual(spare(weeklyData(used: 49)), "~2% spare")
        XCTAssertNotNil(tick(weeklyData(used: 49)))
    }

    func testRunningOutCarriesAnEtaBeforeReset() {
        guard case .runningOut(let eta, _) = weeklyData(used: 60).meterState(now: now) else {
            return XCTFail("expected runningOut")
        }
        XCTAssertNotNil(eta)
    }

    func testRunsOutOnlyWhenBehindAndBeforeReset() {
        let reset = resetsAt(elapsed: 0.33, period: week)
        let eta = Pace.secondsToRunOut(used: 50, limit: 100, resetsAt: reset, periodDuration: week, now: now)
        XCTAssertEqual(eta ?? 0, 0.33 * week, accuracy: week * 0.01)
        XCTAssertNil(Pace.secondsToRunOut(used: 30, limit: 100, resetsAt: reset, periodDuration: week, now: now))
    }

    func testPlentyRemainingSuppressesFalseRunOutFlame() {
        let session: TimeInterval = 5 * 3600
        let elapsed = 240 / session // 5시간 window에서 4분 경과
        var data = WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent,
                              used: 2, limit: 100)
        data.resetsAt = resetsAt(elapsed: elapsed, period: session)
        data.periodDurationMs = Int(session * 1000)
        XCTAssertEqual(Pace.evaluate(used: 2, limit: 100,
                                     resetsAt: data.resetsAt!,
                                     periodDuration: session, now: now)?.status, .behind)
        // 사용량 극소 구간은 projection 불신 — level bar 유지
        XCTAssertEqual(data.meterState(now: now), .level(.normal))
    }

    func testOnePercentAtProjectionGateDoesNotBecomeRed() {
        let session: TimeInterval = 5 * 3600
        var data = WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent,
                              used: 1, limit: 100)
        data.resetsAt = resetsAt(elapsed: 0.01, period: session)
        data.periodDurationMs = Int(session * 1000)
        XCTAssertEqual(Pace.evaluate(used: 1, limit: 100,
                                     resetsAt: data.resetsAt!,
                                     periodDuration: session, now: now)?.status, .onTrack)
        XCTAssertEqual(data.meterState(now: now), .level(.normal))
    }

    func testRunOutFlameShowsOnceFivePercentUsedDespiteHighRemaining() {
        let session: TimeInterval = 5 * 3600
        let elapsed = 240 / session
        var data = WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent,
                              used: 6, limit: 100)
        data.resetsAt = resetsAt(elapsed: elapsed, period: session)
        data.periodDurationMs = Int(session * 1000)
        XCTAssertEqual(Pace.evaluate(used: 6, limit: 100,
                                     resetsAt: data.resetsAt!,
                                     periodDuration: session, now: now)?.status, .behind)
        guard case .runningOut = data.meterState(now: now) else {
            return XCTFail("expected runningOut when burning fast with ≥5% used")
        }
    }

    func testPaceProjectionWaitsUntilWindowHasMateriallyStarted() {
        let session: TimeInterval = 5 * 3600
        let elapsed = 60 / session // 1분 경과 — 외삽하기엔 이름
        let reset = resetsAt(elapsed: elapsed, period: session)
        XCTAssertNil(Pace.evaluate(used: 1, limit: 100, resetsAt: reset, periodDuration: session, now: now))
    }

    // MARK: Always Show Pacing (opt-in tick + healthy copy on blue)

    private func pacedData(used: Double, elapsed: Double, displayMode: WidgetDisplayMode = .used,
                           alwaysShowPacing: Bool = false) -> WidgetData {
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent,
                              used: used, limit: 100, displayMode: displayMode)
        data.resetsAt = resetsAt(elapsed: elapsed, period: week)
        data.periodDurationMs = Int(week * 1000)
        data.alwaysShowPacing = alwaysShowPacing
        return data
    }

    func testHealthyBarHasNoTickByDefault() {
        XCTAssertNil(tick(pacedData(used: 30, elapsed: 0.4)))
    }

    func testAlwaysShowPacingAddsEvenPaceTickToHealthyBar() {
        XCTAssertEqual(tick(pacedData(used: 30, elapsed: 0.4, alwaysShowPacing: true)) ?? -1,
                       0.4, accuracy: 0.001)
        XCTAssertEqual(tick(pacedData(used: 30, elapsed: 0.4, displayMode: .remaining,
                                     alwaysShowPacing: true)) ?? -1,
                       0.6, accuracy: 0.001)
    }

    func testEvenPaceNotchInLeftViewSitsInsideTheFill() {
        XCTAssertEqual(tick(pacedData(used: 2, elapsed: 0.30, displayMode: .remaining,
                                     alwaysShowPacing: true)) ?? -1,
                       0.70, accuracy: 0.001)
    }

    func testAmberTickIsAlwaysEvenPaceLine() {
        XCTAssertEqual(tick(pacedData(used: 46, elapsed: 0.5)) ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(tick(pacedData(used: 46, elapsed: 0.5, alwaysShowPacing: true)) ?? -1,
                       0.5, accuracy: 0.001)
        XCTAssertEqual(spare(pacedData(used: 46, elapsed: 0.5, alwaysShowPacing: true)), "~8% spare")
    }

    func testEvenPaceTickTracksDisplayMode() {
        XCTAssertEqual(tick(pacedData(used: 76, elapsed: 0.8, alwaysShowPacing: true)) ?? -1,
                       0.8, accuracy: 0.001)
        XCTAssertEqual(tick(pacedData(used: 76, elapsed: 0.8, displayMode: .remaining,
                                      alwaysShowPacing: true)) ?? -1,
                       0.2, accuracy: 0.001)
    }

    func testRedBarShowsEvenPaceTickWithAlwaysShowPacingOn() {
        XCTAssertEqual(tick(pacedData(used: 60, elapsed: 0.5, alwaysShowPacing: true)) ?? -1,
                       0.5, accuracy: 0.001)
        XCTAssertNil(tick(pacedData(used: 100, elapsed: 0.5, alwaysShowPacing: true)))
    }

    func testAlwaysShowPacingLeavesRowsWithoutResetWindowPlain() {
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"), kind: .dollars,
                              used: 12, limit: 20)
        data.alwaysShowPacing = true
        XCTAssertNil(tick(data))
        XCTAssertNil(data.meterState(now: now).tooltip)
    }
}
