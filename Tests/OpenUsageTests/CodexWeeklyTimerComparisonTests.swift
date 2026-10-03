import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerComparisonTests: XCTestCase {
    func testFirstFreshOnlySeedsBaselineAndSameFutureResetDoesNotSend() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        let reset = probe.start.addingTimeInterval(900)
        probe.receive(coordinator, reset: reset)
        XCTAssertFalse(coordinator.hasPendingWork)
        probe.now = probe.now.addingTimeInterval(1)
        probe.receive(coordinator, reset: reset)
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertTrue(probe.executed.isEmpty)
        probe.now = probe.now.addingTimeInterval(1)
        probe.receive(coordinator, reset: reset.addingTimeInterval(61))
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.executed, ["a"])
    }

    func testRelativeDisplayResetsCannotTriggerAbsoluteComparison() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        for offset: TimeInterval in [900, 901, 902] {
            var observation = probe.observation(reset: probe.start.addingTimeInterval(offset))
            observation.rawResetAt = nil
            coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!, observation: observation)
        }
        XCTAssertFalse(coordinator.hasPendingWork)
        probe.receive(coordinator, reset: probe.start.addingTimeInterval(903))
        XCTAssertFalse(coordinator.hasPendingWork)
        probe.receive(coordinator, reset: probe.start.addingTimeInterval(964))
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.executed, ["a"])
    }

    func testReturningToZeroCannotRestartAConfirmedUsageWindow() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        let reset = probe.start.addingTimeInterval(900)
        probe.receive(coordinator, used: 0.1, reset: reset)
        probe.now = probe.now.addingTimeInterval(1)
        probe.receive(coordinator, used: 0, reset: reset)
        XCTAssertFalse(coordinator.hasPendingWork)
        probe.receive(coordinator, used: 0, reset: reset.addingTimeInterval(61))
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertTrue(probe.executed.isEmpty)
    }

    func testOneFuturePostObservationDoesNotConfirmTimerEvenWhenPreparationMatches() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(900)
        probe.verification = [probe.observation(reset: probe.preparationReset), nil, nil]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertEqual(probe.executed.count, 1)
        XCTAssertEqual(probe.reports, ["Weekly timer message completed, but the server reset time could not be confirmed."])
    }

    func testFailedMiddleReadBreaksConsecutivePostComparison() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.verification = [probe.observation(reset: reset), nil, probe.observation(reset: reset)]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertNotNil(probe.reports.last!)
    }

    func testRelativeOnlyPostObservationsCannotConfirmTimer() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        var relative = probe.observation(reset: probe.start.addingTimeInterval(900))
        relative.rawResetAt = nil
        probe.verification = [relative, relative, relative]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertNil(try probe.store.attempt(for: "a")?.resetAfter)
        XCTAssertNotNil(probe.reports.last!)
    }

    func testMovingPostResetDoesNotConfirmOrExtendCooldownAndCanRetryAfterFiveMinutes() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.verification = [900.0, 965.0, 1030.0].map { probe.observation(reset: probe.start.addingTimeInterval($0)) }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertNotNil(probe.reports.last!)
        for offset: TimeInterval in [200, 260, 364] {
            probe.now = probe.start.addingTimeInterval(offset)
            probe.receive(coordinator, reset: probe.now.addingTimeInterval(900))
        }
        XCTAssertEqual(probe.executed.count, 1)
        XCTAssertEqual(try probe.store.attempt(for: "a")?.notBefore, probe.start.addingTimeInterval(365))
        probe.now = probe.start.addingTimeInterval(430)
        probe.receive(coordinator, reset: probe.now.addingTimeInterval(900))
        await settle { probe.finished.count == 2 }
        XCTAssertEqual(probe.executed.count, 2)
    }

    func testStablePostResultBecomesNextNormalBaselineWithoutUsageIncrease() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.verification = [probe.observation(reset: reset), probe.observation(reset: reset)]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 2)
        XCTAssertEqual(probe.reports.count, 1)
        XCTAssertNil(probe.reports[0])
        probe.now = probe.start.addingTimeInterval(366)
        probe.receive(coordinator, reset: reset)
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertEqual(probe.executed.count, 1)
        probe.receive(coordinator, reset: reset.addingTimeInterval(61))
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertEqual(probe.executed.count, 1)

        let restarted = probe.coordinator()
        probe.now = probe.start.addingTimeInterval(601)
        probe.receive(restarted, reset: reset.addingTimeInterval(122))
        XCTAssertFalse(restarted.hasPendingWork)
        XCTAssertEqual(probe.executed.count, 1)
    }

    func testTimerStartedElsewhereBetweenNormalReadsDoesNotSend() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        let original = probe.start.addingTimeInterval(604_800)
        probe.receive(coordinator, reset: original)
        probe.now = probe.start.addingTimeInterval(600)
        probe.preparationReset = original.addingTimeInterval(90)
        probe.preparationResetMoves = false
        probe.receive(coordinator, reset: probe.preparationReset)

        await settle { !coordinator.hasPendingWork }

        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testExpiredResetAtPreparationNeverSends() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(-1)
        let coordinator = probe.coordinator()
        probe.receive(coordinator)

        await settle { !coordinator.hasPendingWork }

        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testNewerDuplicateCardDuringPreparationReplacesStaleCandidate() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        try probe.add(providerID: "alias", accountKey: "a")
        let coordinator = probe.coordinator()
        probe.preparationHook = {
            probe.preparationHook = nil
            probe.receive(coordinator, providerID: "alias")
        }
        probe.receive(coordinator)

        await settle { !coordinator.hasPendingWork }

        XCTAssertEqual(probe.executed, ["a"])
    }

    func testDuplicatePostTimestampDoesNotConfirmTimer() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.stampVerification = false
        var duplicate = probe.observation(reset: probe.start.addingTimeInterval(900))
        duplicate.observedAt = probe.start.addingTimeInterval(1)
        probe.verification = [duplicate, duplicate, duplicate]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertNotNil(probe.reports.last!)
    }

    func testPostReadLatencyCannotConfirmBeforeTheRequiredObservationInterval() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.stampVerification = false
        let reset = probe.start.addingTimeInterval(900)
        var first = probe.observation(reset: reset)
        first.observedAt = probe.start.addingTimeInterval(65.1)
        var second = first
        second.observedAt = probe.start.addingTimeInterval(130.099)
        probe.verification = [first, second, nil]
        let coordinator = probe.coordinator()

        probe.receive(coordinator)
        await settle { !coordinator.hasPendingWork }

        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertNotNil(probe.reports.last!)
    }

    func testNewerNormalObservationDuringPreparationInvalidatesOldCandidate() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        probe.preparationHook = { probe.receive(coordinator, used: 0.1) }
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testPreparationWithoutRawResetSkipsMessage() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = nil
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testPreparationConfirmingSameFutureResetSkipsMessage() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.preparationReset = reset
        probe.preparationResetMoves = false
        probe.preparationHook = { probe.now = probe.now.addingTimeInterval(65) }
        let coordinator = probe.coordinator()
        probe.receive(coordinator, reset: reset)
        await settle { probe.finished.count == 1 }
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testRapidAliasObservationDoesNotEraseMovingResetCandidate() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        try probe.add(providerID: "alias", accountKey: "a")
        let reset = probe.start.addingTimeInterval(900)
        let coordinator = probe.coordinator()
        probe.receive(coordinator, reset: reset)
        probe.receive(coordinator, providerID: "alias", reset: reset)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.executed, ["a"])
    }

    func testSlowFirstPostReadDoesNotTreatRapidFollowingReadsAsStable() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.preparationReset = reset
        probe.verification = [probe.observation(reset: reset), probe.observation(reset: reset), probe.observation(reset: reset)]
        probe.verificationHook = {
            if probe.verificationTimes.isEmpty { probe.now = probe.now.addingTimeInterval(131) }
        }
        let coordinator = probe.coordinator()
        probe.receive(coordinator, reset: reset)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertEqual(probe.waits, [.seconds(65)])
        XCTAssertEqual(probe.reports, ["Weekly timer message completed, but the server reset time could not be confirmed."])
    }

    func testAllFailedPostReadsNeedTwoLateSamplesEvenIfResetMatchesBeforeMessage() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.preparationReset = reset
        let coordinator = probe.coordinator()
        probe.receive(coordinator, reset: reset)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.reports.count, 1)
        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports.count, 1)
        probe.now = probe.now.addingTimeInterval(65)
        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports.count, 2)
        XCTAssertNil(probe.reports[1])
        XCTAssertEqual(probe.executed.count, 1)
    }

    func testLateStableResetConfirmsTimerAfterUsageIncreases() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        probe.receive(coordinator, used: 1, reset: reset)
        XCTAssertEqual(probe.reports.count, 1)
        probe.now = probe.now.addingTimeInterval(65)
        probe.receive(coordinator, used: 2, reset: reset)
        XCTAssertEqual(probe.reports.count, 2)
        XCTAssertNil(probe.reports[1])
        XCTAssertEqual(probe.executed.count, 1)
    }

    func testPostResetJitterWithinOneMinuteConfirmsOnlyAfterSixtyFiveSeconds() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.verification = [probe.observation(reset: reset), probe.observation(reset: reset.addingTimeInterval(60))]
        let coordinator = probe.coordinator()

        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }

        let executedAt = try XCTUnwrap(probe.executionTimes.first)
        XCTAssertEqual(probe.verificationTimes.map { $0.timeIntervalSince(executedAt) }, [0, 65])
        XCTAssertEqual(probe.reports.count, 1)
        XCTAssertNil(probe.reports[0])
        probe.now = probe.start.addingTimeInterval(366)
        probe.receive(coordinator, reset: reset.addingTimeInterval(-60))
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertEqual(probe.executed, ["a"])
    }

    func testShortPreparationCannotMistakeMovingResetForStableTimer() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(900)
        probe.preparationReset = reset.addingTimeInterval(1)
        probe.preparationHook = { probe.now = probe.now.addingTimeInterval(1) }
        let coordinator = probe.coordinator()

        probe.receive(coordinator, reset: reset)
        await settle { probe.finished.count == 1 }

        XCTAssertEqual(probe.executed, ["a"])
    }

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Coordinator did not settle", file: file, line: line)
    }
}
