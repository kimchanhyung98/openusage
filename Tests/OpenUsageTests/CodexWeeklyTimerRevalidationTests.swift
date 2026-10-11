import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerRevalidationTests: XCTestCase {
    func testEarlyResetStartsNewWindowFromNormalRefresh() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        let oldReset = probe.start.addingTimeInterval(3 * 86_400)
        _ = try probe.store.observe(accountKey: "a", rawResetAt: oldReset,
                                    observedAt: probe.start.addingTimeInterval(-3_600), usedPercent: 40)
        let newReset = probe.start.addingTimeInterval(7 * 86_400)
        probe.preparationReset = newReset
        let confirmed = newReset.addingTimeInterval(65)
        probe.verification = [probe.observation(reset: confirmed), probe.observation(reset: confirmed)]
        let coordinator = probe.coordinator()

        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(reset: newReset))
        await settle { !coordinator.hasPendingWork }

        XCTAssertEqual(probe.executed, ["a"], "An early reset must not stay blocked by the previous week's confirmation")
        XCTAssertEqual(probe.executionTimes, [probe.start.addingTimeInterval(65)])
        XCTAssertEqual(try probe.store.attempt(for: "a")?.execution, .completed)
    }

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Coordinator did not settle", file: file, line: line)
    }

    func testFixedResetRetainsConfirmationWithoutSending() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(3 * 86_400)
        _ = try probe.store.observe(accountKey: "a", rawResetAt: reset,
                                    observedAt: probe.start.addingTimeInterval(-3_600), usedPercent: 40)
        probe.preparationReset = reset
        probe.preparationResetMoves = false
        let coordinator = probe.coordinator()

        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(reset: reset), checkUnconfirmedReset: true)
        await settle { !coordinator.hasPendingWork }

        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertTrue(probe.waits.isEmpty)
        XCTAssertTrue(probe.finished.isEmpty)
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
        XCTAssertFalse(try probe.store.canAttempt(accountKey: "a", now: probe.now))
    }

    func testTimerStartedManuallyDuringRecheckDoesNotSend() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let reset = probe.start.addingTimeInterval(7 * 86_400)
        probe.preparationReset = reset
        probe.preparationHook = {
            if probe.prepared.count == 2 { probe.preparationResetMoves = false }
        }
        let coordinator = probe.coordinator()

        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(reset: reset), checkUnconfirmedReset: true)
        await settle { !coordinator.hasPendingWork }

        XCTAssertEqual(probe.prepared.count, 2)
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testNonzeroUsageDoesNotPrepareOrSend() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()

        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(used: 0.1, reset: probe.start.addingTimeInterval(604_800)),
                            checkUnconfirmedReset: true)

        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertTrue(probe.executed.isEmpty)
    }

    func testConcurrentNormalObservationCancelsScheduledPreparation() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        probe.preparationHook = {
            if probe.prepared.count == 2 { probe.receive(coordinator, used: 1) }
        }

        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(reset: probe.start.addingTimeInterval(900)),
                            checkUnconfirmedReset: true)
        await settle { !coordinator.hasPendingWork }

        XCTAssertEqual(probe.prepared.count, 2)
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
        probe.preparationHook = nil
    }
}
