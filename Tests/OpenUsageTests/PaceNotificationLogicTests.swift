import XCTest
@testable import OpenUsage

private extension PaceNotificationToggles {
    static let allOn = PaceNotificationToggles(
        underTenPercent: true,
        healthyToClose: true,
        closeToRunningOut: true
    )
}

final class PaceNotificationLogicTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_700_000_000)

    // under-10% rule의 의도치 않은 동시 발화 방지용 여유 fraction
    private let healthy = WidgetData.MeterState.healthy(projectedFraction: 0.5)
    private let close = WidgetData.MeterState.closeToLimit(spare: "~5% spare", projectedFraction: 0.95)
    private let running = WidgetData.MeterState.runningOut(eta: nil, projectedFraction: 1.2)

    private func step(
        _ state: WidgetData.MeterState,
        fraction: Double = 0.5,
        resetsAt: Date? = nil,
        from previous: NotificationState = NotificationState(),
        toggles: PaceNotificationToggles = .allOn
    ) -> PaceNotificationLogic.Transition {
        PaceNotificationLogic.transitions(
            state: state, fraction: fraction, resetsAt: resetsAt ?? reset,
            previous: previous, toggles: toggles
        )
    }

    // MARK: - Pace-verdict edges

    func testHealthyToCloseFiresOnce() {
        let first = step(healthy)
        XCTAssertTrue(first.fire.isEmpty)
        let second = step(close, from: first.newState)
        XCTAssertEqual(second.fire, [.healthyToClose])
    }

    func testStayingYellowDoesNotRefire() {
        var state = step(healthy).newState
        state = step(close, from: state).newState
        let again = step(close, from: state)
        XCTAssertTrue(again.fire.isEmpty)
    }

    func testCloseToRunningOutFires() {
        var state = step(healthy).newState
        state = step(close, from: state).newState
        let red = step(running, from: state)
        XCTAssertEqual(red.fire, [.closeToRunningOut])
    }

    func testJumpStraightFromHealthyToRedFiresCritical() {
        let state = step(healthy).newState
        let red = step(running, from: state)
        XCTAssertEqual(red.fire, [.closeToRunningOut])
    }

    // MARK: - Under 10% remaining

    func testUnderTenPercentFiresOncePerWindow() {
        let primed = step(close, fraction: 0.50).newState
        let first = step(close, fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        let again = step(close, fraction: 0.05, from: first.newState)
        XCTAssertFalse(again.fire.contains(.underTenPercent))
    }

    // MARK: - Cold start with already-bad state

    func testColdStartPrimesWithoutFiring() {
        let first = step(running, fraction: 0.02)
        XCTAssertTrue(first.fire.isEmpty, "cold start primes, it doesn't fire")
        let recovered = step(healthy, fraction: 0.50, from: first.newState).newState
        let red = step(running, fraction: 0.02, from: recovered)
        XCTAssertTrue(red.fire.contains(.closeToRunningOut))
        XCTAssertTrue(red.fire.contains(.underTenPercent))
    }

    // MARK: - Reset rollover

    func testResetRolloverClearsFiredSetSoItCanFireAgain() {
        var state = step(healthy).newState
        state = step(close, from: state).newState
        XCTAssertTrue(step(close, from: state).fire.isEmpty)
        // 새 reset window: edge 재현을 위해 healthy → close 재진입
        let newReset = reset.addingTimeInterval(3600)
        let rolled = step(healthy, resetsAt: newReset, from: state).newState
        let refired = step(close, resetsAt: newReset, from: rolled)
        XCTAssertEqual(refired.fire, [.healthyToClose])
    }

    func testResetJitterDoesNotRearmRunningOutAlert() {
        var state = step(healthy).newState
        state = step(running, from: state).newState

        let jitteredReset = reset.addingTimeInterval(0.09)
        let stillRunningOut = step(running, resetsAt: jitteredReset, from: state)

        XCTAssertTrue(stillRunningOut.fire.isEmpty)
        XCTAssertEqual(stillRunningOut.newState.previousBucket, .runningOut)
        XCTAssertEqual(stillRunningOut.newState.resetsAt, jitteredReset)
    }

    func testResetJitterDoesNotRearmCloseAlert() {
        var state = step(healthy).newState
        state = step(close, from: state).newState

        let jitteredReset = reset.addingTimeInterval(0.09)
        let stillClose = step(close, resetsAt: jitteredReset, from: state)

        XCTAssertTrue(stillClose.fire.isEmpty)
        XCTAssertEqual(stillClose.newState.previousBucket, .close)
        XCTAssertEqual(stillClose.newState.resetsAt, jitteredReset)
    }

    // MARK: - Recovery re-arms

    func testRecoveryThenReworseningRefires() {
        var state = step(healthy).newState
        state = step(close, from: state).newState
        state = step(running, from: state).newState
        state = step(healthy, from: state).newState
        let close2 = step(close, from: state)
        XCTAssertEqual(close2.fire, [.healthyToClose])
        let red2 = step(running, from: close2.newState)
        XCTAssertEqual(red2.fire, [.closeToRunningOut])
    }

    func testUnderTenPercentReArmsAfterRecoveryAboveTen() {
        let primed = step(close, fraction: 0.50).newState
        let first = step(close, fraction: 0.05, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        let recovered = step(close, fraction: 0.50, from: first.newState)
        XCTAssertFalse(recovered.fire.contains(.underTenPercent))
        let dipsAgain = step(close, fraction: 0.05, from: recovered.newState)
        XCTAssertTrue(dipsAgain.fire.contains(.underTenPercent))
    }

    // MARK: - No data / level-band states

    func testNoDataNeverFires() {
        let result = step(.noData, fraction: 0.01)
        XCTAssertTrue(result.fire.isEmpty)
    }

    func testLevelPrimesWithoutFiringOnFirstObservation() {
        let result = step(.level(.critical), fraction: 0.01)
        XCTAssertTrue(result.fire.isEmpty)
    }

    func testLevelFiresAlmostOutUnderTenPercent() {
        let primed = step(.level(.critical), fraction: 0.20).newState
        let first = step(.level(.critical), fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.underTenPercent))
        XCTAssertFalse(first.fire.contains(.healthyToClose))
        XCTAssertFalse(first.fire.contains(.closeToRunningOut))
    }

    func testUntrackedDoesNotDisturbPreviousSignals() {
        var state = step(healthy).newState
        state = step(.noData, fraction: 0.5, from: state).newState
        let close = step(self.close, from: state)
        XCTAssertEqual(close.fire, [.healthyToClose])
    }

    // MARK: - Toggle gates

    func testMasterOffSuppressionIsCallerSide() {
        // pure 로직에 master flag 없음 — caller가 gate, per-trigger 전부 off로 대신 검증
        let off = PaceNotificationToggles(underTenPercent: false, healthyToClose: false, closeToRunningOut: false)
        let state = step(healthy, toggles: off).newState
        let close = step(self.close, fraction: 0.05, from: state, toggles: off)
        XCTAssertTrue(close.fire.isEmpty)
    }

    func testPerTriggerOffSuppressesOnlyThatMilestone() {
        let toggles = PaceNotificationToggles(underTenPercent: false, healthyToClose: true, closeToRunningOut: false)
        let state = step(healthy, toggles: toggles).newState
        let close = step(self.close, fraction: 0.05, from: state, toggles: toggles)
        XCTAssertEqual(close.fire, [.healthyToClose])
        let red = step(running, fraction: 0.02, from: close.newState, toggles: toggles)
        XCTAssertTrue(red.fire.isEmpty)
    }

    func testOffToggleDoesNotConsumeTheEdge() {
        // trigger off 중의 악화가 crossing을 소비하면 안 됨 — previousBucket 유지
        let off = PaceNotificationToggles(underTenPercent: false, healthyToClose: false, closeToRunningOut: true)
        var state = step(healthy, toggles: off).newState
        let closeSkipped = step(self.close, fraction: 0.20, from: state, toggles: off)
        XCTAssertTrue(closeSkipped.fire.isEmpty)
        state = closeSkipped.newState
        let on = PaceNotificationToggles(underTenPercent: false, healthyToClose: true, closeToRunningOut: true)
        let refired = step(self.close, fraction: 0.20, from: state, toggles: on)
        XCTAssertTrue(refired.fire.contains(.healthyToClose))
    }

    // MARK: - Fresh session window (treated as .level by the caller)

    func testFreshSessionLevelPrimesWithoutFiring() {
        let result = step(.level(.normal), fraction: 0.99)
        XCTAssertTrue(result.fire.isEmpty)
    }
}
