import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TokscaleSyncCooldownTests: XCTestCase {
    func testCompletedSubmitRequiresDismissalBeforeAnotherSubmit() async throws {
        let commandRunner = TokscaleStoreTestCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 0, output: "first result")),
            .init(result: TokscaleCommandResult(exitCode: 0, output: "second result")),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: TokscaleStoreTestBunInstaller(availability: .available(runtime)),
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        store.startSubmit()
        try await waitUntil { !store.isRunning }

        let commandCount = await commandRunner.callCount()
        XCTAssertEqual(commandCount, 1)
        XCTAssertEqual(store.phase, .submitFinished)
        XCTAssertEqual(store.output, "first result")
    }

    func testDismissResultResetsCompletedStateToIdle() async throws {
        let installer = TokscaleStoreTestBunInstaller(availability: .available(runtime))
        let commandRunner = TokscaleStoreTestCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "submit output\n"),
                output: ["submit output\n"]
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        XCTAssertEqual(store.output, "submit output\n")
        XCTAssertFalse(store.isRunning)

        store.dismissResult()

        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(store.output, "")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.failure)
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(store.isSyncCoolingDown)
        XCTAssertNotNil(store.nextSyncAllowedAt)
    }

    func testSyncCooldownBlocksSubmitForTenMinutesThenReEnables() async throws {
        let clock = TokscaleTestClock(Date(timeIntervalSince1970: 1_000_000))
        let installer = TokscaleStoreTestBunInstaller(availability: .available(runtime))
        let commandRunner = TokscaleStoreTestCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "submit 1\n"),
                output: ["submit 1\n"]
            ),
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "submit 2\n"),
                output: ["submit 2\n"]
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner,
            now: { clock.value }
        )

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        XCTAssertFalse(store.isSyncCoolingDown)

        store.dismissResult()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.isSyncCoolingDown)
        XCTAssertEqual(store.nextSyncAllowedAt, clock.value.addingTimeInterval(10 * 60))

        store.startSubmit()
        XCTAssertEqual(store.phase, .idle)
        let commandsDuringCooldown = await commandRunner.callCount()
        XCTAssertEqual(commandsDuringCooldown, 1)

        clock.value.addTimeInterval(599)
        store.startSubmit()
        XCTAssertEqual(store.phase, .idle)
        let commandsBeforeDeadline = await commandRunner.callCount()
        XCTAssertEqual(commandsBeforeDeadline, 1)

        clock.value.addTimeInterval(1)
        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        let commandsAfter10Min = await commandRunner.callCount()
        XCTAssertEqual(commandsAfter10Min, 2)
    }

    func testCooldownStartsWhenResultIsDismissedAndRepeatedDismissalKeepsDeadline() async throws {
        let clock = TokscaleTestClock(Date(timeIntervalSince1970: 1_000_000))
        let runner = TokscaleStoreTestCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 0, output: "No data to submit.")),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: TokscaleStoreTestBunInstaller(availability: .available(runtime)),
            commandRunner: runner,
            now: { clock.value }
        )
        try store.saveDeviceName("studio-mac")
        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }

        clock.value.addTimeInterval(600)
        store.dismissResult()
        let deadline = clock.value.addingTimeInterval(600)
        XCTAssertEqual(store.nextSyncAllowedAt, deadline)
        XCTAssertEqual(store.deviceName, "studio-mac")
        clock.value.addTimeInterval(300)
        store.dismissResult()
        XCTAssertEqual(store.nextSyncAllowedAt, deadline)
        XCTAssertTrue(store.isSyncCoolingDown)
        await store.shutdown()
    }

    func testCooldownExpiresWithoutInteractionOrAutomaticSubmission() async throws {
        let timer = TokscaleTestSleeper()
        let runner = TokscaleStoreTestCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 0, output: "done")),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: TokscaleStoreTestBunInstaller(availability: .available(runtime)),
            commandRunner: runner,
            sleep: { await timer.sleep(for: $0) }
        )
        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        store.dismissResult()
        try await waitUntil { await timer.isWaiting }
        let duration = await timer.duration
        XCTAssertEqual(duration, .seconds(600))

        await timer.resume()
        try await waitUntil { !store.isSyncCoolingDown }

        XCTAssertNil(store.nextSyncAllowedAt)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.output.isEmpty)
        let commands = await runner.callCount()
        XCTAssertEqual(commands, 1)
    }

    func testOldCooldownCannotClearANewDeadlineAfterShutdown() async throws {
        let oldTimer = TokscaleTestSleeper()
        let newTimer = TokscaleTestSleeper()
        let clock = TokscaleTestClock(Date(timeIntervalSince1970: 1_000_000))
        let runner = TokscaleStoreTestCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 0, output: "first")),
            .init(result: TokscaleCommandResult(exitCode: 0, output: "second")),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: TokscaleStoreTestBunInstaller(availability: .available(runtime)),
            commandRunner: runner,
            now: { clock.value },
            sleep: { duration in
                if await oldTimer.duration == nil {
                    await oldTimer.sleep(for: duration)
                } else {
                    await newTimer.sleep(for: duration)
                }
            }
        )
        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        store.dismissResult()
        try await waitUntil { await oldTimer.isWaiting }
        await store.shutdown()
        XCTAssertFalse(store.isSyncCoolingDown)
        XCTAssertNil(store.nextSyncAllowedAt)

        clock.value.addTimeInterval(100)
        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        store.dismissResult()
        try await waitUntil { await newTimer.isWaiting }
        await oldTimer.resume()
        await Task.yield()

        XCTAssertEqual(store.nextSyncAllowedAt, clock.value.addingTimeInterval(600))
        XCTAssertTrue(store.isSyncCoolingDown)
        await newTimer.resume()
        try await waitUntil { !store.isSyncCoolingDown }
    }

    func testLoginResultsCanCloseWithoutDelayingExplicitSubmit() async throws {
        let marker = TokscaleCommandResult.loginRequiredMarker
        let runner = TokscaleStoreTestCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 1, output: marker)),
            .init(result: TokscaleCommandResult(exitCode: 1, output: marker)),
            .init(result: TokscaleCommandResult(exitCode: 0, output: "Logged in.")),
            .init(result: TokscaleCommandResult(exitCode: 0, output: "done")),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: TokscaleStoreTestBunInstaller(availability: .available(runtime)),
            commandRunner: runner
        )
        store.startSubmit()
        try await waitUntil { store.phase == .loginRequired }
        store.dismissResult()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.output.isEmpty)
        XCTAssertFalse(store.isSyncCoolingDown)
        store.startSubmit()
        try await waitUntil { store.phase == .loginRequired }
        store.startLogin()
        try await waitUntil { store.phase == .loginFinished }
        store.dismissResult()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertTrue(store.output.isEmpty)
        XCTAssertFalse(store.isSyncCoolingDown)
        let commandsBeforeSubmit = await runner.commands()
        XCTAssertEqual(commandsBeforeSubmit, [.submit(deviceName: nil), .submit(deviceName: nil), .login])

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }
        let commands = await runner.commands()
        XCTAssertEqual(commands, commandsBeforeSubmit + [.submit(deviceName: nil)])
    }

    func testDismissFailedResultDoesNotTriggerCooldown() async throws {
        let installer = TokscaleStoreTestBunInstaller(availability: .available(runtime))
        let commandRunner = TokscaleStoreTestCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(exitCode: 1, output: "error\n"),
                output: ["error\n"]
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .failed }

        store.dismissResult()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isSyncCoolingDown)
        XCTAssertNil(store.nextSyncAllowedAt)
    }

    func testDismissResultDoesNothingWhileRunning() async throws {
        let installer = TokscaleStoreTestBunInstaller(availability: .available(runtime))
        let commandRunner = TokscaleStoreTestCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "late result"),
                output: ["early output"],
                isSuspended: true
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { await commandRunner.callCount() == 1 }
        XCTAssertTrue(store.isRunning)

        store.dismissResult()
        XCTAssertTrue(store.isRunning)
        XCTAssertNotEqual(store.phase, .idle)

        await commandRunner.releaseSuspendedCall()
        try await waitUntil { !store.isRunning }
    }

    private var runtime: BunRuntime {
        BunRuntime(
            bunURL: URL(fileURLWithPath: "/opt/bun/bin/bun"),
            bunxURL: URL(fileURLWithPath: "/opt/bun/bin/bunx"),
            executionPath: "/opt/bun/bin"
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.TokscaleSyncStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

@MainActor
private final class TokscaleTestClock {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

private actor TokscaleTestSleeper {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var duration: Duration?
    var isWaiting: Bool { continuation != nil }

    func sleep(for duration: Duration) async {
        self.duration = duration
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
