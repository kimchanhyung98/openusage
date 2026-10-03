import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerCoordinatorTests: XCTestCase {
    func testOnlyExactZeroTriggersAndPreparationRechecksUsage() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        probe.receive(coordinator, used: 0.1)
        await Task.yield()
        XCTAssertTrue(probe.prepared.isEmpty)

        probe.preparationUsed = 0.1
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.prepared, ["a"])
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testAccountsRunSeriallyAndDuplicateCardsSendOnce() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        try probe.add(providerID: "alias", accountKey: "a")
        try probe.add(providerID: "second", accountKey: "b")
        var release: CheckedContinuation<Void, Never>?
        probe.executionHook = { key in
            if key == "a" { await withCheckedContinuation { release = $0 } }
        }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        probe.receive(coordinator, providerID: "alias")
        probe.receive(coordinator, providerID: "second")
        await settle { release != nil }
        XCTAssertEqual(probe.executed, ["a"])
        XCTAssertTrue(coordinator.isRunning(providerID: "alias"))
        probe.receive(coordinator, providerID: "alias")
        release?.resume()
        await settle { probe.executed == ["a", "b"] && !coordinator.hasPendingWork }
        XCTAssertEqual(probe.executed, ["a", "b"])
        XCTAssertFalse(coordinator.isRunning(providerID: "codex"))
    }

    func testReservationExistsBeforeExecutionAndSurvivesRestartAndResetChanges() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        var reserved: CodexWeeklyTimerAttempt?
        probe.executionHook = { key in reserved = try? probe.store.attempt(for: key) }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(reserved?.execution, .pending)
        XCTAssertEqual(reserved?.notBefore, probe.start.addingTimeInterval(300))

        let restarted = probe.coordinator()
        probe.receive(restarted, reset: probe.now.addingTimeInterval(200))
        probe.receive(restarted, reset: probe.now.addingTimeInterval(400))
        await Task.yield()
        XCTAssertEqual(probe.executed, ["a"])
        let persisted = try CodexWeeklyTimerAttemptStore(fileURL: probe.store.fileURL).attempt(for: "a")
        XCTAssertEqual(persisted?.id, reserved?.id)
        XCTAssertEqual(persisted?.notBefore, probe.start.addingTimeInterval(300))
    }

    func testExpiredHoldNeedsFreshZeroAndAllowsNextCycle() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        probe.now = probe.start.addingTimeInterval(301)
        probe.receive(coordinator, used: 0.1)
        await Task.yield()
        XCTAssertEqual(probe.executed.count, 1)
        probe.receive(coordinator)
        await settle { probe.finished.count == 2 }
        XCTAssertEqual(probe.executed, ["a", "a"])
    }

    func testVerificationRunsAtZeroSixtyFiveAndOneHundredThirtySecondsAndStoresServerReset() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.verification = [nil, probe.observation(reset: probe.start.addingTimeInterval(900)),
                              probe.observation(reset: probe.start.addingTimeInterval(900))]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.map { $0.timeIntervalSince(probe.start) }, [0, 65, 130])
        XCTAssertEqual(probe.waits, [.seconds(65), .seconds(65)])
        let attempt = try XCTUnwrap(probe.store.attempt(for: "a"))
        XCTAssertEqual(attempt.notBefore, probe.start.addingTimeInterval(300))
        XCTAssertEqual(attempt.resetAfter, probe.start.addingTimeInterval(900))
        XCTAssertEqual(probe.reports.count, 1)
        XCTAssertNil(probe.reports[0])
    }

    func testStablePostResetRetainsExecutionFailure() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.result = .init(launched: true, completed: false, updatedAuth: nil, failureDescription: "Message failed.")
        probe.verification = [probe.observation(reset: probe.start.addingTimeInterval(900)),
                              probe.observation(reset: probe.start.addingTimeInterval(900))]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 2)
        XCTAssertEqual(probe.reports, ["Message failed."])
        XCTAssertEqual(try probe.store.attempt(for: "a")?.execution, .failed)
        probe.receive(coordinator)
        await Task.yield()
        XCTAssertEqual(probe.executed.count, 1)
    }

    func testUnknownCompletionRetainsFixedCooldownWhenVerificationFails() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(800)
        probe.result = .init(launched: true, completed: false, updatedAuth: nil, failureDescription: nil)
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertEqual(try probe.store.attempt(for: "a")?.notBefore, probe.start.addingTimeInterval(300))
        XCTAssertEqual(probe.reports, ["Weekly timer message completion could not be confirmed. Automatic retries wait five minutes."])
    }

    func testPrelaunchFailureKeepsCooldownAndDoesNotBlockNextAccount() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        try probe.add(providerID: "second", accountKey: "b")
        probe.result = .init(launched: false, completed: false, updatedAuth: nil, failureDescription: "CLI missing.")
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        probe.receive(coordinator, providerID: "second")
        await settle { probe.finished.count == 2 }
        XCTAssertEqual(probe.executed, ["a", "b"])
        XCTAssertEqual(try probe.store.attempt(for: "a")?.execution, .failed)
        XCTAssertEqual(try probe.store.attempt(for: "b")?.execution, .failed)
        XCTAssertTrue(probe.verificationTimes.isEmpty)
        probe.receive(coordinator)
        XCTAssertEqual(probe.executed, ["a", "b"])
        probe.now = probe.start.addingTimeInterval(301)
        probe.receive(coordinator)
        await settle { probe.finished.count == 3 }
        XCTAssertEqual(probe.executed, ["a", "b", "a"])
    }

    func testDisableDuringPreparationPreventsLaunch() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationHook = { probe.enabled = false }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertNil(try probe.store.attempt(for: "a"))
    }

    func testRebindingDuringExecutionDoesNotPublishToReplacement() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.executionHook = { _ in probe.bindings["codex"] = UUID() }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertTrue(probe.reports.isEmpty)
        XCTAssertTrue(probe.verificationTimes.isEmpty)
        XCTAssertNotNil(try probe.store.attempt(for: "a"))
    }

    func testStopAfterLaunchRetainsReservationAndDoesNotVerify() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        var release: CheckedContinuation<Void, Never>?
        probe.executionHook = { _ in await withCheckedContinuation { release = $0 } }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { release != nil }
        coordinator.stop()
        release?.resume()
        await settle { !coordinator.hasPendingWork }
        XCTAssertNotNil(try probe.store.attempt(for: "a"))
        XCTAssertTrue(probe.verificationTimes.isEmpty)
        XCTAssertTrue(probe.reports.isEmpty)
        XCTAssertTrue(probe.finished.isEmpty)
    }

    func testShutdownAwaitsExecutionCleanupAndDropsQueuedAccounts() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        try probe.add(providerID: "second", accountKey: "b")
        var release: CheckedContinuation<Void, Never>?
        var cleanedUp = false
        var shutdownStarted = false
        var shutdownFinished = false
        probe.executionHook = { _ in
            await withCheckedContinuation { release = $0 }
            XCTAssertTrue(Task.isCancelled)
            cleanedUp = true
        }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        probe.receive(coordinator, providerID: "second")
        await settle { release != nil }
        XCTAssertTrue(coordinator.hasPendingWork)
        let shutdown = Task {
            shutdownStarted = true
            await coordinator.shutdown()
            shutdownFinished = true
        }
        await settle { shutdownStarted }
        XCTAssertFalse(shutdownFinished)
        XCTAssertFalse(cleanedUp)
        XCTAssertTrue(coordinator.hasPendingWork)
        release?.resume()
        await shutdown.value
        XCTAssertTrue(cleanedUp)
        XCTAssertTrue(shutdownFinished)
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertEqual(probe.executed, ["a"])
        XCTAssertTrue(probe.finished.isEmpty)
        XCTAssertTrue(probe.verificationTimes.isEmpty)
        XCTAssertNotNil(try probe.store.attempt(for: "a"))
        probe.receive(coordinator, providerID: "second")
        XCTAssertFalse(coordinator.hasPendingWork)
    }

    func testCorruptStateFailsClosedWithoutErasingRecord() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let corrupt = Data("broken-state".utf8)
        try corrupt.write(to: probe.store.fileURL)
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await Task.yield()
        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertEqual(probe.reports.count, 1)
        XCTAssertEqual(try Data(contentsOf: probe.store.fileURL), corrupt)
    }

    func testStateSaveFailureAfterPreparationPreventsExecution() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationHook = {
            try? FileManager.default.removeItem(at: probe.directory)
            try? Data("unwritable-parent".utf8).write(to: probe.directory)
        }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertEqual(probe.reports, ["Weekly timer automation could not save its state. No message was sent."])
    }

    func testVerificationFromAnotherAccountCannotReplaceHold() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.verification = [probe.observation(accountKey: "different", reset: probe.start.addingTimeInterval(800))]
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.verificationTimes.count, 3)
        XCTAssertEqual(try probe.store.attempt(for: "a")?.notBefore, probe.start.addingTimeInterval(300))
        XCTAssertNil(try probe.store.attempt(for: "a")?.resetAfter)
    }

    func testChangedBindingDoesNotSuspendReplacementRefresh() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        var release: CheckedContinuation<Void, Never>?
        probe.executionHook = { _ in await withCheckedContinuation { release = $0 } }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { release != nil }
        XCTAssertTrue(coordinator.isRunning(providerID: "codex", bindingID: probe.bindings["codex"]!))
        XCTAssertFalse(coordinator.isRunning(providerID: "codex", bindingID: UUID()))
        release?.resume()
        await settle { probe.finished.count == 1 }
    }

    func testLaterLiveResetClearsOnlyVerificationFailureWithoutResending() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        let coordinator = probe.coordinator()
        probe.receive(coordinator)
        await settle { probe.finished.count == 1 }
        XCTAssertEqual(probe.reports, ["Weekly timer message completed, but the server reset time could not be confirmed."])
        let reset = probe.now.addingTimeInterval(800)
        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports.count, 1)
        probe.now = probe.now.addingTimeInterval(65)
        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports.count, 2)
        XCTAssertNil(probe.reports[1])
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
