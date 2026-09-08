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

    fileprivate var standardInput: Data {
        switch self {
        case .submit:
            Data("n\n".utf8)
        case .login:
            Data()
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

    // 미등록 키는 전달하지 않음. 경로 탐색과 Tokscale 인증에 필요한 값만 명시적으로 유지.
    private static let allowedEnvironmentKeys = Set([
        "USER", "LOGNAME", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES",
        "LC_TIME", "LC_NUMERIC", "LC_MONETARY", "LC_COLLATE", "TZ", "TMPDIR", "DO_NOT_TRACK",
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "CURL_CA_BUNDLE",
        "BUN_CONFIG_REGISTRY",
        "TOKSCALE_API_TOKEN", "TOKSCALE_CONFIG_DIR", "TOKSCALE_EXTRA_DIRS", "TOKSCALE_HEADLESS_DIR",
        "TOKSCALE_NATIVE_TIMEOUT_MS", "TOKSCALE_DEVICE_ID", "TOKSCALE_DEVICE_NAME",
        "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR",
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME", "KIMI_CODE_HOME",
        "HERMES_HOME", "CODEBUFF_DATA_DIR", "FREEBUFF_DATA_DIR", "GROK_HOME", "JCODE_HOME",
        "GJC_CODING_AGENT_DIR", "GJC_CONFIG_DIR", "PI_CONFIG_DIR",
        "SENPI_CODING_AGENT_DIR", "SENPI_CODING_AGENT_SESSION_DIR", "KIMCHI_CODING_AGENT_DIR",
        "PRIME_AGENT_CODING_AGENT_DIR", "PRIME_AGENT_SESSION_DIR", "PRIME_AGENT_CODING_AGENT_SESSION_DIR",
        "DSH_HOME", "LM_STUDIO_HOME", "UNSLOTH_STUDIO_HOME", "HINDSIGHT_HOME",
        "REASONIX_STATE_HOME", "REASONIX_HOME", "GOOSE_PATH_ROOT", "CRUSH_GLOBAL_DATA",
        "COPILOT_OTEL_FILE_EXPORTER_PATH", "OPENCODE_CONFIG", "OPENCODE_CONFIG_DIR",
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
            standardInput: command.standardInput,
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
            Self.allowedEnvironmentKeys.contains(key)
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
