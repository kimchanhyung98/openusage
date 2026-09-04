import Foundation

enum TokscaleDeviceNameError: LocalizedError, Equatable {
    case empty
    case containsControlCharacter
    case tooLong

    var errorDescription: String? {
        switch self {
        case .empty:
            "Enter a device name."
        case .containsControlCharacter:
            "Device names can’t contain control characters."
        case .tooLong:
            "Device names must be 120 UTF-8 bytes or fewer."
        }
    }
}

struct TokscaleDeviceName: Sendable, Equatable {
    static let maximumUTF8ByteCount = 120

    let value: String

    init(_ rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw TokscaleDeviceNameError.empty }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TokscaleDeviceNameError.containsControlCharacter
        }
        guard value.utf8.count <= Self.maximumUTF8ByteCount else {
            throw TokscaleDeviceNameError.tooLong
        }
        self.value = value
    }
}

enum TokscaleCommand: Sendable, Equatable {
    case submit(deviceName: TokscaleDeviceName?)
    case login

    fileprivate var arguments: [String] {
        switch self {
        case .submit:
            ["tokscale@latest", "submit"]
        case .login:
            ["tokscale@latest", "login"]
        }
    }
}

struct TokscaleCommandResult: Sendable, Equatable {
    static let loginRequiredMarker = "Not logged in."

    var exitCode: Int32
    var output: String
    private var observedLoginRequiredMarker: Bool

    init(exitCode: Int32, output: String, observedLoginRequiredMarker: Bool = false) {
        self.exitCode = exitCode
        self.output = output
        self.observedLoginRequiredMarker = observedLoginRequiredMarker
            || output.contains(Self.loginRequiredMarker)
    }

    var requiresLogin: Bool {
        exitCode != 0 && observedLoginRequiredMarker
    }
}

protocol TokscaleCommandRunning: Sendable {
    func run(
        _ command: TokscaleCommand,
        runtime: BunRuntime,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> TokscaleCommandResult
}

struct TokscaleCommandRunner: TokscaleCommandRunning, Sendable {
    static let timeout: TimeInterval = 15 * 60
    static let outputLimit = 64 * 1024

    private static let excludedEnvironmentKeys = Set([
        "TOKSCALE_API_URL",
        "NODE_OPTIONS", "NODE_PATH", "BUN_OPTIONS",
        "LD_PRELOAD", "LD_LIBRARY_PATH",
    ])
    private static let systemPathDirectories = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    private let processRunner: any StreamingProcessRunning
    private let inheritedEnvironment: [String: String]
    private let loginShellEnvironment: @Sendable () -> [String: String]?
    private let homeDirectoryURL: URL

    init(
        processRunner: any StreamingProcessRunning = StreamingProcessRunner(),
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellEnvironment: @escaping @Sendable () -> [String: String]? = {
            LoginShellEnvironment.shared.environmentSnapshot()
        },
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.processRunner = processRunner
        self.inheritedEnvironment = inheritedEnvironment
        self.loginShellEnvironment = loginShellEnvironment
        self.homeDirectoryURL = homeDirectoryURL
    }

    func run(
        _ command: TokscaleCommand,
        runtime: BunRuntime,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> TokscaleCommandResult {
        let request = StreamingProcessRequest(
            executableURL: runtime.bunxURL,
            arguments: command.arguments,
            environment: environment(for: command, executionPath: runtime.executionPath),
            currentDirectoryURL: homeDirectoryURL,
            timeout: Self.timeout,
            outputLimit: Self.outputLimit
        )
        let markerDetector = TokscaleLoginRequiredMarkerDetector()
        let result = try await processRunner.run(request) { chunk in
            markerDetector.observe(chunk)
            onOutput(chunk)
        }
        return TokscaleCommandResult(
            exitCode: result.exitCode,
            output: result.output,
            observedLoginRequiredMarker: markerDetector.observedMarker
        )
    }

    private func environment(for command: TokscaleCommand, executionPath: String) -> [String: String] {
        let shellEnvironment = loginShellEnvironment() ?? [:]
        var source = shellEnvironment
        source.merge(inheritedEnvironment) { _, processValue in
            processValue
        }
        var environment = source.filter { key, _ in
            !Self.excludedEnvironmentKeys.contains(key)
                && !key.hasPrefix("DYLD_")
                && !key.hasPrefix("TOKSCALE_FAKE_")
                && !key.hasPrefix("TOKSCALE_TEST_")
        }
        environment["HOME"] = homeDirectoryURL.path
        environment["PWD"] = homeDirectoryURL.path
        environment["PATH"] = Self.safeExecutionPath([
            executionPath,
            inheritedEnvironment["PATH"],
            shellEnvironment["PATH"],
        ])
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        switch command {
        case .submit(let deviceName):
            if let deviceName {
                environment["TOKSCALE_DEVICE_NAME"] = deviceName.value
            }
        case .login:
            environment.removeValue(forKey: "TOKSCALE_DEVICE_NAME")
        }
        return environment
    }

    private static func safeExecutionPath(_ values: [String?]) -> String {
        var directories = systemPathDirectories
        for value in values.compactMap({ $0 }) {
            for directory in value.split(separator: ":", omittingEmptySubsequences: false).map(String.init) {
                guard (directory as NSString).isAbsolutePath,
                      !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                      !directories.contains(directory) else { continue }
                directories.append(directory)
            }
        }
        return directories.joined(separator: ":")
    }
}

private final class TokscaleLoginRequiredMarkerDetector: @unchecked Sendable {
    private let lock = NSLock()
    private var didObserveMarker = false
    private var trailingOutput = ""

    var observedMarker: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didObserveMarker
    }

    func observe(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        let candidate = trailingOutput + chunk
        if candidate.contains(TokscaleCommandResult.loginRequiredMarker) {
            didObserveMarker = true
        }
        let retainedCount = max(0, TokscaleCommandResult.loginRequiredMarker.count - 1)
        trailingOutput = String(candidate.suffix(retainedCount))
    }
}
