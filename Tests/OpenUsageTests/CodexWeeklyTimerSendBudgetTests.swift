import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerSendBudgetTests: XCTestCase {
    func testRepeatedMovingResetAndMissingVerificationAreBoundedAcrossRestart() async throws {
        for restart in [false, true] {
            let probe = try WeeklyTimerProbe(seedBaseline: false)
            defer { probe.cleanup() }
            probe.preparationReset = probe.start.addingTimeInterval(604_800)
            _ = try probe.store.observe(accountKey: "a", rawResetAt: probe.start.addingTimeInterval(86_400),
                                        observedAt: probe.start.addingTimeInterval(-600), usedPercent: 40)
            var coordinator = probe.coordinator()
            for index in 0..<288 {
                probe.now = probe.start.addingTimeInterval(Double(index) * 300)
                if restart {
                    await coordinator.shutdown()
                    coordinator = probe.coordinator()
                }
                coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                                    observation: probe.observation(reset: probe.now.addingTimeInterval(604_800)),
                                    checkUnconfirmedReset: index % 3 == 0)
                await settle(coordinator)
            }
            XCTAssertEqual(probe.executed.count, 2, "restart=\(restart)")
            XCTAssertTrue(probe.reports.compactMap { $0 }.contains { $0.contains("24 hours") })
            await coordinator.shutdown()
        }
    }

    func testSuccessfulVerificationCannotBypassBudgetAtNextScheduledCheck() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(604_800)
        probe.executionHook = { _ in
            let reset = probe.now.addingTimeInterval(604_800)
            probe.verification = [probe.observation(reset: reset), probe.observation(reset: reset)]
        }
        let coordinator = probe.coordinator()
        for index in 0..<96 {
            probe.now = probe.start.addingTimeInterval(Double(index) * 900)
            coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                                observation: probe.observation(reset: probe.now.addingTimeInterval(604_800)),
                                checkUnconfirmedReset: true)
            await settle(coordinator)
        }
        XCTAssertEqual(probe.executed.count, 2)
        await coordinator.shutdown()
        probe.executionHook = nil
    }

    func testReservationsPersistAndAllowOnlyTwoAttemptsInAnyRollingDay() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        var reservations: [Date] = []
        for index in 0..<(2 * 288) {
            let now = probe.start.addingTimeInterval(Double(index) * 300)
            let restarted = CodexWeeklyTimerAttemptStore(fileURL: probe.store.fileURL)
            if let attempt = try restarted.begin(accountKey: "a", resetBefore: nil, now: now) {
                reservations.append(attempt.attemptedAt)
            }
            XCTAssertLessThanOrEqual(reservations.filter { now.timeIntervalSince($0) < 86_400 }.count, 2)
        }
        XCTAssertEqual(reservations.count, 4)
        XCTAssertNotNil(try probe.store.begin(accountKey: "another-account", resetBefore: nil, now: probe.start))
    }

    func testFailedAndPendingAttemptsDoNotRefundBudget() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        var attempt = try XCTUnwrap(probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start))
        attempt.execution = .failed
        try probe.store.update(accountKey: "a", attempt: attempt)
        XCTAssertNotNil(try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(300)))
        XCTAssertNil(try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(600)))
        XCTAssertFalse(try probe.store.canAttempt(accountKey: "a", now: probe.start.addingTimeInterval(600)))
        XCTAssertNil(try probe.store.revalidationState(accountKey: "a", now: probe.start.addingTimeInterval(600)))
    }

    func testLegacyAttemptsBlockForOneDayWithoutDiscardingConfirmation() throws {
        for version in [1, 2] {
            let probe = try WeeklyTimerProbe(seedBaseline: false)
            defer { probe.cleanup() }
            let attempt = try XCTUnwrap(probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start))
            let reset = probe.start.addingTimeInterval(604_800)
            _ = try probe.store.observe(accountKey: "a", rawResetAt: reset, observedAt: probe.start, usedPercent: 40)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: probe.store.fileURL)) as? [String: Any])
            document["version"] = version
            document["sendHistory"] = nil
            try JSONSerialization.data(withJSONObject: document).write(to: probe.store.fileURL)
            let restarted = CodexWeeklyTimerAttemptStore(fileURL: probe.store.fileURL)
            XCTAssertEqual(try restarted.attempt(for: "a")?.id, attempt.id)
            XCTAssertEqual(try restarted.sendLimitResetsAt(accountKey: "a", now: probe.start.addingTimeInterval(300)),
                           probe.start.addingTimeInterval(86_400))
            XCTAssertNil(try restarted.revalidationState(accountKey: "a", now: probe.start.addingTimeInterval(86_399)))
            XCTAssertEqual(try restarted.revalidationState(accountKey: "a", now: probe.start.addingTimeInterval(86_400))?.confirmedReset, reset)
        }
    }

    func testMissingOrTamperedHistoryFailsClosed() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        _ = try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start)
        let saved = try Data(contentsOf: probe.store.fileURL)
        for value: [String: Any]? in [nil, [:], ["invalid-key": []]] {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            document["sendHistory"] = value
            let corrupt = try JSONSerialization.data(withJSONObject: document)
            try corrupt.write(to: probe.store.fileURL)
            XCTAssertThrowsError(try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(300)))
            XCTAssertEqual(try Data(contentsOf: probe.store.fileURL), corrupt)
        }
    }

    func testConfirmedStableTimerDoesNotShowLimitWarningOnScheduledRead() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        for offset: TimeInterval in [-700, -350] {
            _ = try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(offset))
        }
        let reset = probe.start.addingTimeInterval(604_800)
        _ = try probe.store.observe(accountKey: "a", rawResetAt: reset,
                                    observedAt: probe.start.addingTimeInterval(-100), usedPercent: 10)
        let coordinator = probe.coordinator()
        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(reset: reset), checkUnconfirmedReset: true)
        await settle(coordinator)
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertTrue(probe.reports.isEmpty)
        await coordinator.shutdown()
    }

    func testStableTimerClearsLimitWarningWithoutReleasingBudget() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        for offset: TimeInterval in [-700, -350] {
            XCTAssertNotNil(try probe.store.begin(accountKey: "a", resetBefore: nil,
                                                 now: probe.start.addingTimeInterval(offset)))
        }
        let coordinator = probe.coordinator()
        let reset = probe.start.addingTimeInterval(604_800)
        let limitExpires = try XCTUnwrap(probe.store.sendLimitResetsAt(accountKey: "a", now: probe.now))

        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports.count, 1)
        let limitWarning = try XCTUnwrap(probe.reports.first ?? nil)
        XCTAssertTrue(limitWarning.contains("24 hours"))

        probe.now = probe.now.addingTimeInterval(65)
        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports, [limitWarning, nil])
        XCTAssertEqual(try probe.store.sendLimitResetsAt(accountKey: "a", now: probe.now), limitExpires)

        probe.now = probe.now.addingTimeInterval(900)
        probe.receive(coordinator, reset: reset.addingTimeInterval(900))
        await settle(coordinator)
        XCTAssertEqual(probe.reports, [limitWarning, nil, limitWarning])
        XCTAssertEqual(try probe.store.sendLimitResetsAt(accountKey: "a", now: probe.now), limitExpires)
        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertTrue(probe.executed.isEmpty)
        await coordinator.shutdown()
    }

    func testUncertainCompletionWithMovingVerificationCannotKeepSending() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(604_800)
        probe.result.completed = false
        probe.verificationHook = {
            probe.verification = [probe.observation(reset: probe.now.addingTimeInterval(604_800))]
        }
        let coordinator = probe.coordinator()
        for index in 0..<96 {
            probe.now = probe.start.addingTimeInterval(Double(index) * 900)
            coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                                observation: probe.observation(reset: probe.now.addingTimeInterval(604_800)),
                                checkUnconfirmedReset: true)
            await settle(coordinator)
        }
        XCTAssertEqual(probe.executed.count, 2)
        await coordinator.shutdown()
        probe.verificationHook = nil
    }

    private func settle(_ coordinator: CodexWeeklyTimerCoordinator) async {
        for _ in 0..<500 {
            if !coordinator.hasPendingWork { return }
            await Task.yield()
        }
        XCTFail("Coordinator did not finish")
    }
}
