import Foundation
@testable import OpenUsage

enum TokscaleStoreTestError: Error, Sendable {
    case failed
}

actor TokscaleStoreTestBunInstaller: BunInstalling {
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

actor UnsafeDirectoryBunInstaller: BunInstalling {
    func availability() async throws -> BunAvailability {
        .missing
    }

    func install(onOutput: @escaping @Sendable (String) -> Void) async throws -> BunRuntime {
        throw BunInstallerError.unsafeInstallDirectory
    }
}

actor TokscaleStoreTestCommandRunner: TokscaleCommandRunning {
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
