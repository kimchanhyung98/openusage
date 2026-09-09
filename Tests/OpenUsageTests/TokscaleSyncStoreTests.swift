import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TokscaleSyncStoreTests: XCTestCase {
    func testInitIsInertAndLoadsOnlyAValidatedSavedName() async throws {
        let defaults = makeDefaults()
        defaults.set("  m1-max  ", forKey: TokscaleSyncStore.deviceNameKey)
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [])

        let store = TokscaleSyncStore(
            defaults: defaults,
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        XCTAssertEqual(store.deviceName, "m1-max")
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isRunning)
        let availabilityCalls = await installer.availabilityCallCount()
        let installCalls = await installer.installCallCount()
        let commandCalls = await commandRunner.callCount()
        XCTAssertEqual(availabilityCalls, 0)
        XCTAssertEqual(installCalls, 0)
        XCTAssertEqual(commandCalls, 0)
    }

    func testSavingNameValidatesAndPersistsWithoutStartingWork() async throws {
        let defaults = makeDefaults()
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [])
        let store = TokscaleSyncStore(
            defaults: defaults,
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        try store.saveDeviceName("  studio-mac  ")

        XCTAssertEqual(store.deviceName, "studio-mac")
        XCTAssertEqual(defaults.string(forKey: TokscaleSyncStore.deviceNameKey), "studio-mac")
        XCTAssertThrowsError(try store.saveDeviceName("bad\nname"))
        XCTAssertEqual(store.deviceName, "studio-mac")
        let availabilityCalls = await installer.availabilityCallCount()
        let installCalls = await installer.installCallCount()
        let commandCalls = await commandRunner.callCount()
        XCTAssertEqual(availabilityCalls, 0)
        XCTAssertEqual(installCalls, 0)
        XCTAssertEqual(commandCalls, 0)
    }

    func testClearingNameRemovesOnlyTheLocalOverride() throws {
        let defaults = makeDefaults()
        let store = TokscaleSyncStore(
            defaults: defaults,
            bunInstaller: StubBunInstaller(availability: .available(runtime)),
            commandRunner: StubTokscaleCommandRunner(responses: [])
        )
        try store.saveDeviceName("m1-max")

        store.clearDeviceName()

        XCTAssertNil(store.deviceName)
        XCTAssertNil(defaults.string(forKey: TokscaleSyncStore.deviceNameKey))
        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isRunning)
    }

    func testMissingBunInstallsThenContinuesTheSameSubmit() async throws {
        let defaults = makeDefaults()
        let installer = StubBunInstaller(
            availability: .missing,
            installResult: .success(runtime),
            installOutput: ["installer output\n"]
        )
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "submit output\n"),
                output: ["submit output\n"]
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: defaults,
            bunInstaller: installer,
            commandRunner: commandRunner
        )
        try store.saveDeviceName("m1-max")

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }

        let availabilityCalls = await installer.availabilityCallCount()
        let installCalls = await installer.installCallCount()
        XCTAssertEqual(availabilityCalls, 1)
        XCTAssertEqual(installCalls, 1)
        let commands = await commandRunner.commands()
        let expectedName = try TokscaleDeviceName("m1-max")
        XCTAssertEqual(commands, [.submit(deviceName: expectedName)])
        XCTAssertEqual(store.output, "installer output\nsubmit output\n")
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.isRunning)
    }

    func testOnlyOneSubmitCanRunAtATime() async throws {
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 0, output: "done"), isSuspended: true),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        store.startSubmit()
        try await waitUntil { await commandRunner.callCount() == 1 }
        store.startSubmit()

        XCTAssertTrue(store.isRunning)
        let callsWhileSuspended = await commandRunner.callCount()
        XCTAssertEqual(callsWhileSuspended, 1)
        await commandRunner.releaseSuspendedCall()
        try await waitUntil { store.phase == .submitFinished }
        let finalCalls = await commandRunner.callCount()
        XCTAssertEqual(finalCalls, 1)
    }

    func testExactMissingLoginResultOffersLoginAndLoginNeverSubmits() async throws {
        let missingLoginOutput = TokscaleCommandResult.loginRequiredMarker
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 1, output: missingLoginOutput)),
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "Login complete."),
                output: ["Login complete."]
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .loginRequired }
        store.startLogin()
        try await waitUntil { store.phase == .loginFinished }

        let commands = await commandRunner.commands()
        let installCalls = await installer.installCallCount()
        XCTAssertEqual(commands, [.submit(deviceName: nil), .login])
        XCTAssertEqual(installCalls, 0)
        XCTAssertFalse(store.isRunning)
    }

    func testFailedLoginCanRetryWithoutStartingSubmit() async throws {
        let missingLoginOutput = TokscaleCommandResult.loginRequiredMarker
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 1, output: missingLoginOutput)),
            .init(result: TokscaleCommandResult(exitCode: 4, output: "Denied.")),
            .init(result: TokscaleCommandResult(exitCode: 0, output: "Login complete.")),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .loginRequired }
        store.startLogin()
        try await waitUntil { store.phase == .failed }
        XCTAssertEqual(store.failure, .login)

        store.startLogin()
        try await waitUntil { store.phase == .loginFinished }

        let commands = await commandRunner.commands()
        XCTAssertEqual(commands, [.submit(deviceName: nil), .login, .login])
    }

    func testBunWithoutBunxFailsWithoutInstallOrCommand() async throws {
        let installer = StubBunInstaller(availability: .bunxMissing)
        let commandRunner = StubTokscaleCommandRunner(responses: [])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .failed }

        XCTAssertEqual(store.failure, .bunxMissing)
        XCTAssertEqual(store.failure?.offersBunInstallationGuide, true)
        let installCalls = await installer.installCallCount()
        let commandCalls = await commandRunner.callCount()
        XCTAssertEqual(installCalls, 0)
        XCTAssertEqual(commandCalls, 0)
    }

    func testUnsafeBunInstallDirectoryExplainsWhyAutomaticInstallStopped() async throws {
        let installer = UnsafeDirectoryBunInstaller()
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: StubTokscaleCommandRunner(responses: [])
        )

        store.startSubmit()
        try await waitUntil { store.phase == .failed }

        XCTAssertEqual(store.failure, .bunInstallation)
        XCTAssertEqual(
            store.errorMessage,
            BunInstallerError.unsafeInstallDirectory.errorDescription
        )
    }

    func testNonzeroSubmitIsANormalFailureUnlessLoginMarkerMatches() async throws {
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(
                    exitCode: 7,
                    output: "Run 'bunx tokscale@latest login'."
                )
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .failed }

        XCTAssertEqual(store.failure, .submit)
        XCTAssertEqual(
            store.errorMessage,
            "Tokscale finished with status 7. Review the command output and try again."
        )
    }

    func testOutputIsBoundedWhilePreservingItsBeginningAndEnd() async throws {
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "fallback"),
                output: ["BEGIN\n", String(repeating: "x", count: TokscaleCommandRunner.outputLimit * 2), "\nEND"]
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .submitFinished }

        XCTAssertLessThanOrEqual(store.output.utf8.count, TokscaleCommandRunner.outputLimit)
        XCTAssertTrue(store.output.hasPrefix("BEGIN\n"))
        XCTAssertTrue(store.output.hasSuffix("\nEND"))
        XCTAssertTrue(store.output.contains("output truncated"))
    }

    func testCancelLoginRejectsLateOutputAndWaitsForChildTermination() async throws {
        let missingLoginOutput = TokscaleCommandResult.loginRequiredMarker
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
            .init(result: TokscaleCommandResult(exitCode: 1, output: missingLoginOutput)),
            .init(
                result: TokscaleCommandResult(exitCode: 0, output: "late result"),
                output: ["authorization code"],
                isSuspended: true
            ),
        ])
        let store = TokscaleSyncStore(
            defaults: makeDefaults(),
            bunInstaller: installer,
            commandRunner: commandRunner
        )

        store.startSubmit()
        try await waitUntil { store.phase == .loginRequired }
        store.startLogin()
        try await waitUntil { await commandRunner.callCount() == 2 }
        store.cancelLogin()

        XCTAssertEqual(store.phase, .loginRequired)
        XCTAssertTrue(store.isRunning)
        XCTAssertEqual(store.output, "")
        await commandRunner.emitToSuspendedCall("late secret")
        await Task.yield()
        XCTAssertEqual(store.output, "")
        store.startSubmit()
        let callsWhileCancelling = await commandRunner.callCount()
        XCTAssertEqual(callsWhileCancelling, 2)

        await commandRunner.releaseSuspendedCall()
        try await waitUntil { !store.isRunning }
        XCTAssertEqual(store.phase, .loginRequired)
        XCTAssertEqual(store.output, "")
    }

    func testShutdownCancelsAndInvalidatesAnActiveOperation() async throws {
        let installer = StubBunInstaller(availability: .available(runtime))
        let commandRunner = StubTokscaleCommandRunner(responses: [
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
        let shutdownTask = Task { @MainActor in
            await store.shutdown()
        }
        await Task.yield()
        await commandRunner.emitToSuspendedCall("late output")
        await commandRunner.releaseSuspendedCall()
        await shutdownTask.value

        XCTAssertEqual(store.phase, .idle)
        XCTAssertFalse(store.isRunning)
        XCTAssertEqual(store.output, "")
        XCTAssertNil(store.errorMessage)
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

private enum TokscaleStoreTestError: Error, Sendable {
    case failed
}

private actor StubBunInstaller: BunInstalling {
    private let availabilityResult: Result<BunAvailability, TokscaleStoreTestError>
    private let installResult: Result<BunRuntime, TokscaleStoreTestError>
    private let installOutput: [String]
    private var availabilityCalls = 0
    private var installCalls = 0

    init(
        availability: BunAvailability,
        installResult: Result<BunRuntime, TokscaleStoreTestError> = .failure(.failed),
        installOutput: [String] = []
    ) {
        self.availabilityResult = .success(availability)
        self.installResult = installResult
        self.installOutput = installOutput
    }

    func availability() async throws -> BunAvailability {
        availabilityCalls += 1
        return try availabilityResult.get()
    }

    func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> BunRuntime {
        installCalls += 1
        for chunk in installOutput { onOutput(chunk) }
        return try installResult.get()
    }

    func availabilityCallCount() -> Int {
        availabilityCalls
    }

    func installCallCount() -> Int {
        installCalls
    }
}

private actor UnsafeDirectoryBunInstaller: BunInstalling {
    func availability() async throws -> BunAvailability {
        .missing
    }

    func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> BunRuntime {
        throw BunInstallerError.unsafeInstallDirectory
    }
}

private actor StubTokscaleCommandRunner: TokscaleCommandRunning {
    struct Response: Sendable {
        let result: TokscaleCommandResult
        var output: [String] = []
        var isSuspended = false
    }

    private var responses: [Response]
    private var recordedCommands: [TokscaleCommand] = []
    private var suspendedContinuation: CheckedContinuation<Void, Never>?
    private var suspendedOutput: (@Sendable (String) -> Void)?

    init(responses: [Response]) {
        self.responses = responses
    }

    func run(
        _ command: TokscaleCommand,
        runtime: BunRuntime,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> TokscaleCommandResult {
        recordedCommands.append(command)
        guard !responses.isEmpty else { throw TokscaleStoreTestError.failed }
        let response = responses.removeFirst()
        for chunk in response.output { onOutput(chunk) }
        if response.isSuspended {
            suspendedOutput = onOutput
            await withCheckedContinuation { continuation in
                suspendedContinuation = continuation
            }
            suspendedOutput = nil
        }
        return response.result
    }

    func callCount() -> Int {
        recordedCommands.count
    }

    func commands() -> [TokscaleCommand] {
        recordedCommands
    }

    func emitToSuspendedCall(_ output: String) {
        suspendedOutput?(output)
    }

    func releaseSuspendedCall() {
        suspendedContinuation?.resume()
        suspendedContinuation = nil
    }
}
