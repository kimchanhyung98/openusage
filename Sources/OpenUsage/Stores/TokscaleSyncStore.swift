import Foundation
import Observation

enum TokscaleSyncPhase: Equatable {
    case idle
    case installingBun
    case submitting
    case loginRequired
    case submitFinished
    case loggingIn
    case loginFinished
    case failed
}

enum TokscaleSyncFailure: Equatable {
    case bunCheck
    case bunInstallation
    case bunxMissing
    case submit
    case login

    var offersBunInstallationGuide: Bool {
        switch self {
        case .bunCheck, .bunInstallation, .bunxMissing:
            true
        case .submit, .login:
            false
        }
    }
}

@MainActor
@Observable
final class TokscaleSyncStore {
    static let deviceNameKey = "openusage.tokscale.deviceName.v1"

    private(set) var phase: TokscaleSyncPhase = .idle
    private(set) var deviceName: String?
    private(set) var output = ""
    private(set) var errorMessage: String?
    private(set) var failure: TokscaleSyncFailure?
    private(set) var isRunning = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let bunInstaller: any BunInstalling
    @ObservationIgnored private let commandRunner: any TokscaleCommandRunning
    @ObservationIgnored private var activeTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration = 0
    @ObservationIgnored private var acceptsOutput = false

    init(
        defaults: UserDefaults = .standard,
        bunInstaller: any BunInstalling = BunInstaller(),
        commandRunner: any TokscaleCommandRunning = TokscaleCommandRunner()
    ) {
        self.defaults = defaults
        self.bunInstaller = bunInstaller
        self.commandRunner = commandRunner
        if let saved = defaults.string(forKey: Self.deviceNameKey) {
            do {
                deviceName = try TokscaleDeviceName(saved).value
            } catch {
                deviceName = nil
                AppLog.warn(.config, "Saved Tokscale device name is invalid; ignoring it")
            }
        } else {
            deviceName = nil
        }
    }

    func saveDeviceName(_ rawValue: String) throws {
        let validated = try TokscaleDeviceName(rawValue)
        deviceName = validated.value
        defaults.set(validated.value, forKey: Self.deviceNameKey)
    }

    func clearDeviceName() {
        deviceName = nil
        defaults.removeObject(forKey: Self.deviceNameKey)
    }

    func startSubmit() {
        guard activeTask == nil else { return }
        let name = deviceName.flatMap { try? TokscaleDeviceName($0) }
        let generation = beginOperation(initialPhase: .submitting)
        activeTask = Task { @MainActor [weak self] in
            await self?.performSubmit(deviceName: name, generation: generation)
        }
    }

    func startLogin() {
        guard activeTask == nil,
              phase == .loginRequired || (phase == .failed && failure == .login) else { return }
        let generation = beginOperation(initialPhase: .loggingIn)
        activeTask = Task { @MainActor [weak self] in
            await self?.performLogin(generation: generation)
        }
    }

    func cancelLogin() {
        guard phase == .loggingIn, activeTask != nil else { return }
        activeTask?.cancel()
        acceptsOutput = false
        output = ""
        errorMessage = nil
        failure = nil
        phase = .loginRequired
    }

    func shutdown() async {
        let task = activeTask
        operationGeneration &+= 1
        task?.cancel()
        isRunning = false
        acceptsOutput = false
        output = ""
        errorMessage = nil
        failure = nil
        phase = .idle
        if let task {
            await task.value
        }
        activeTask = nil
    }

    private func performSubmit(deviceName: TokscaleDeviceName?, generation: Int) async {
        let outputRelay = makeOutputRelay(generation: generation)
        let availability: BunAvailability
        do {
            availability = try await bunInstaller.availability()
            try Task.checkCancellation()
        } catch {
            finish(
                error: .bunCheck,
                message: Self.safeBunMessage(for: error, fallbackFailure: .bunCheck),
                generation: generation
            )
            return
        }

        let runtime: BunRuntime
        switch availability {
        case .available(let availableRuntime):
            runtime = availableRuntime
        case .missing:
            guard isCurrent(generation) else { return }
            phase = .installingBun
            do {
                runtime = try await bunInstaller.install { outputRelay.receive($0) }
                try Task.checkCancellation()
            } catch {
                publishFinalOutput(from: outputRelay, generation: generation)
                finish(
                    error: .bunInstallation,
                    message: Self.safeBunMessage(for: error, fallbackFailure: .bunInstallation),
                    generation: generation
                )
                return
            }
        case .bunxMissing:
            finish(error: .bunxMissing, generation: generation)
            return
        }

        guard isCurrent(generation) else { return }
        phase = .submitting
        do {
            let result = try await commandRunner.run(
                .submit(deviceName: deviceName),
                runtime: runtime,
                onOutput: { outputRelay.receive($0) }
            )
            try Task.checkCancellation()
            guard isCurrent(generation) else { return }
            publishFinalOutput(from: outputRelay, fallback: result.output, generation: generation)
            if result.exitCode == 0 {
                finish(phase: .submitFinished, generation: generation)
            } else if result.requiresLogin {
                finish(phase: .loginRequired, generation: generation)
            } else {
                finish(error: .submit, exitCode: result.exitCode, generation: generation)
            }
        } catch {
            publishFinalOutput(from: outputRelay, generation: generation)
            finish(error: .submit, generation: generation)
        }
    }

    private func performLogin(generation: Int) async {
        let outputRelay = makeOutputRelay(generation: generation)
        let availability: BunAvailability
        do {
            availability = try await bunInstaller.availability()
            try Task.checkCancellation()
        } catch {
            finish(
                error: .bunCheck,
                message: Self.safeBunMessage(for: error, fallbackFailure: .bunCheck),
                generation: generation
            )
            return
        }

        let runtime: BunRuntime
        switch availability {
        case .available(let availableRuntime):
            runtime = availableRuntime
        case .missing:
            finish(error: .bunInstallation, generation: generation)
            return
        case .bunxMissing:
            finish(error: .bunxMissing, generation: generation)
            return
        }

        do {
            let result = try await commandRunner.run(
                .login,
                runtime: runtime,
                onOutput: { outputRelay.receive($0) }
            )
            try Task.checkCancellation()
            guard isCurrent(generation) else { return }
            publishFinalOutput(from: outputRelay, fallback: result.output, generation: generation)
            if result.exitCode == 0 {
                finish(phase: .loginFinished, generation: generation)
            } else {
                finish(error: .login, exitCode: result.exitCode, generation: generation)
            }
        } catch {
            publishFinalOutput(from: outputRelay, generation: generation)
            finish(error: .login, generation: generation)
        }
    }

    private func beginOperation(initialPhase: TokscaleSyncPhase) -> Int {
        operationGeneration &+= 1
        output = ""
        errorMessage = nil
        failure = nil
        phase = initialPhase
        acceptsOutput = true
        isRunning = true
        return operationGeneration
    }

    private func makeOutputRelay(generation: Int) -> TokscaleOutputRelay {
        TokscaleOutputRelay(limit: TokscaleCommandRunner.outputLimit) { [weak self] snapshot in
            guard let self, self.isCurrent(generation), self.acceptsOutput else { return }
            self.output = snapshot
        }
    }

    private func publishFinalOutput(
        from relay: TokscaleOutputRelay,
        fallback: String = "",
        generation: Int
    ) {
        guard isCurrent(generation), acceptsOutput else { return }
        let streamed = relay.snapshot
        output = streamed.isEmpty ? TokscaleOutputRelay.bounded(fallback, limit: TokscaleCommandRunner.outputLimit) : streamed
    }

    private func finish(phase: TokscaleSyncPhase, generation: Int) {
        guard isCurrent(generation) else { return }
        self.phase = phase
        acceptsOutput = false
        activeTask = nil
        isRunning = false
    }

    private func finish(
        error failure: TokscaleSyncFailure,
        exitCode: Int32? = nil,
        message: String? = nil,
        generation: Int
    ) {
        guard isCurrent(generation) else { return }
        if Task.isCancelled {
            acceptsOutput = false
            activeTask = nil
            isRunning = false
            return
        }
        self.failure = failure
        errorMessage = message ?? Self.message(for: failure, exitCode: exitCode)
        phase = .failed
        acceptsOutput = false
        activeTask = nil
        isRunning = false
        if let exitCode {
            AppLog.warn(.subprocess, "Tokscale command exited with status \(exitCode)")
        } else {
            AppLog.error(.subprocess, "Tokscale operation failed before completion")
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        operationGeneration == generation && activeTask != nil
    }

    private static func message(for failure: TokscaleSyncFailure, exitCode: Int32?) -> String {
        switch failure {
        case .bunCheck:
            "OpenUsage couldn’t check for Bun. Try again."
        case .bunInstallation:
            "OpenUsage couldn’t install or verify Bun. Install it manually and try again."
        case .bunxMissing:
            "Bun is installed, but bunx couldn’t be found. Repair the Bun installation and try again."
        case .submit:
            exitCode.map { "Tokscale finished with status \($0). Review the command output and try again." }
                ?? "OpenUsage couldn’t run Tokscale. Try again."
        case .login:
            exitCode.map { "Tokscale login finished with status \($0). Review the command output and try again." }
                ?? "OpenUsage couldn’t run Tokscale login. Try again."
        }
    }

    private static func safeBunMessage(for error: Error, fallbackFailure: TokscaleSyncFailure) -> String {
        if let error = error as? BunInstallerError, let description = error.errorDescription {
            return description
        }
        if let error = error as? StreamingProcessRunnerError, let description = error.errorDescription {
            return description
        }
        return message(for: fallbackFailure, exitCode: nil)
    }
}

private final class TokscaleOutputRelay: @unchecked Sendable {
    private static let truncationMarker = "\n… output truncated …\n"

    private let lock = NSLock()
    private let limit: Int
    private let deliver: @MainActor @Sendable (String) -> Void
    private var head = ""
    private var tail = ""
    private var complete = ""
    private var isTruncated = false
    private var deliveryScheduled = false

    init(limit: Int, deliver: @escaping @MainActor @Sendable (String) -> Void) {
        self.limit = limit
        self.deliver = deliver
    }

    var snapshot: String {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func receive(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        appendLocked(chunk)
        guard !deliveryScheduled else {
            lock.unlock()
            return
        }
        deliveryScheduled = true
        lock.unlock()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = self.takeSnapshotForDelivery()
            self.deliver(snapshot)
        }
    }

    static func bounded(_ value: String, limit: Int) -> String {
        let relay = TokscaleOutputRelay(limit: limit) { _ in }
        relay.lock.lock()
        relay.appendLocked(value)
        let snapshot = relay.snapshotLocked()
        relay.lock.unlock()
        return snapshot
    }

    private func appendLocked(_ chunk: String) {
        if !isTruncated {
            let combined = complete + chunk
            guard combined.utf8.count > limit else {
                complete = combined
                return
            }
            isTruncated = true
            complete = ""
            let contentLimit = max(0, limit - Self.truncationMarker.utf8.count)
            let headLimit = contentLimit / 2
            let tailLimit = contentLimit - headLimit
            head = Self.prefix(combined, maximumBytes: headLimit)
            tail = Self.suffix(combined, maximumBytes: tailLimit)
            return
        }

        let contentLimit = max(0, limit - Self.truncationMarker.utf8.count)
        let tailLimit = contentLimit - (contentLimit / 2)
        tail = Self.suffix(tail + chunk, maximumBytes: tailLimit)
    }

    private func snapshotLocked() -> String {
        isTruncated ? head + Self.truncationMarker + tail : complete
    }

    private func takeSnapshotForDelivery() -> String {
        lock.lock()
        defer { lock.unlock() }
        deliveryScheduled = false
        return snapshotLocked()
    }

    private static func prefix(_ value: String, maximumBytes: Int) -> String {
        var end = value.startIndex
        var byteCount = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextByteCount = byteCount + value[end..<next].utf8.count
            guard nextByteCount <= maximumBytes else { break }
            byteCount = nextByteCount
            end = next
        }
        return String(value[..<end])
    }

    private static func suffix(_ value: String, maximumBytes: Int) -> String {
        var start = value.endIndex
        var byteCount = 0
        while start > value.startIndex {
            let previous = value.index(before: start)
            let nextByteCount = byteCount + value[previous..<start].utf8.count
            guard nextByteCount <= maximumBytes else { break }
            byteCount = nextByteCount
            start = previous
        }
        return String(value[start...])
    }
}
