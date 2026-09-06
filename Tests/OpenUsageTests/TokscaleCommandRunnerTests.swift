import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class TokscaleCommandRunnerTests: XCTestCase {
    func testDeviceNameTrimsAndValidatesUTF8ByteLimit() throws {
        XCTAssertEqual(try TokscaleDeviceName("  m1-max \n").value, "m1-max")
        XCTAssertEqual(try TokscaleDeviceName(String(repeating: "a", count: 120)).value.utf8.count, 120)
        XCTAssertEqual(try TokscaleDeviceName(String(repeating: "가", count: 40)).value.utf8.count, 120)

        XCTAssertThrowsError(try TokscaleDeviceName(" \n ")) { error in
            XCTAssertEqual(error as? TokscaleDeviceNameError, .empty)
        }
        XCTAssertThrowsError(try TokscaleDeviceName("mac\u{0000}name")) { error in
            XCTAssertEqual(error as? TokscaleDeviceNameError, .containsControlCharacter)
        }
        XCTAssertThrowsError(try TokscaleDeviceName(String(repeating: "가", count: 41))) { error in
            XCTAssertEqual(error as? TokscaleDeviceNameError, .tooLong)
        }
    }

    func testSubmitUsesFixedArgumentsHomeDirectoryAndMergedEnvironment() async throws {
        let processRunner = RecordingTokscaleProcessRunner(
            result: StreamingProcessResult(exitCode: 0, output: "finished")
        )
        let runner = TokscaleCommandRunner(
            processRunner: processRunner,
            inheritedEnvironment: [
                "USER": "tester",
                "LANG": "en_US.UTF-8",
                "HTTPS_PROXY": "https://proxy.example",
                "SSL_CERT_FILE": "/certs/root.pem",
                "CLAUDE_CONFIG_DIR": "/Users/tester/.claude-custom",
                "CODEX_HOME": "/Users/tester/.codex-custom",
                "XDG_CONFIG_HOME": "/Users/tester/.config",
                "XDG_DATA_HOME": "relative/data",
                "KIMI_CODE_HOME": "/tmp/unsafe\npath",
                "TOKSCALE_API_TOKEN": "secret-token",
                "TOKSCALE_API_URL": "https://override.example",
                "TOKSCALE_DEVICE_ID": "forced-device",
                "TOKSCALE_OTHER": "other",
                "TOKSCALE_FM_DEBUG": "1",
                "TOKSCALE_NATIVE_TIMEOUT_MS": "600000",
                "TOKSCALE_FAKE_CODEX_MODE": "fixture",
                "NODE_OPTIONS": "--require=/tmp/inject.js",
                "BUN_OPTIONS": "--preload=/tmp/inject.js",
                "DYLD_INSERT_LIBRARIES": "/tmp/inject.dylib",
                "LD_LIBRARY_PATH": "/tmp/inject",
                "GH_TOKEN": "github-secret",
                "GITHUB_TOKEN": "github-secret",
                "UNRELATED_SECRET": "secret",
                "BUN_CONFIG_REGISTRY": "https://registry.example",
                "HOME": "/attacker-home",
                "PATH": "/attacker-bin",
            ],
            loginShellEnvironment: {
                [
                    "PATH": "/Users/tester/.local/bin:/opt/homebrew/bin",
                    "GEMINI_CLI_HOME": "/Users/tester/.gemini-custom",
                    "FUTURE_PROVIDER_HOME": "/Users/tester/.future-provider",
                    "TOKSCALE_EXTRA_DIRS": "codex:/Users/tester/more-sessions,claude:relative/sessions,bad-entry",
                ]
            },
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let runtime = BunRuntime(
            bunURL: URL(fileURLWithPath: "/opt/bun/bin/bun"),
            bunxURL: URL(fileURLWithPath: "/opt/bun/bin/bunx"),
            executionPath: "/opt/bun/bin:/usr/local/bin:relative::/usr/bin"
        )
        let name = try TokscaleDeviceName("m1-max")

        let result = try await runner.run(.submit(deviceName: name), runtime: runtime) { _ in }

        XCTAssertEqual(result, TokscaleCommandResult(exitCode: 0, output: "finished"))
        let recordedRequest = await processRunner.request()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.executableURL, runtime.bunxURL)
        XCTAssertEqual(request.arguments, ["tokscale@latest", "submit"])
        XCTAssertEqual(request.environment["HOME"], "/Users/tester")
        XCTAssertEqual(request.environment["PWD"], "/Users/tester")
        XCTAssertEqual(
            request.environment["PATH"],
            "/usr/bin:/bin:/usr/sbin:/sbin:/opt/bun/bin:/usr/local/bin:/attacker-bin:/Users/tester/.local/bin:/opt/homebrew/bin"
        )
        XCTAssertEqual(request.environment["TERM"], "dumb")
        XCTAssertEqual(request.environment["NO_COLOR"], "1")
        XCTAssertEqual(request.environment["TOKSCALE_DEVICE_NAME"], "m1-max")
        XCTAssertEqual(request.environment["CLAUDE_CONFIG_DIR"], "/Users/tester/.claude-custom")
        XCTAssertEqual(request.environment["CODEX_HOME"], "/Users/tester/.codex-custom")
        XCTAssertEqual(request.environment["GEMINI_CLI_HOME"], "/Users/tester/.gemini-custom")
        XCTAssertEqual(request.environment["FUTURE_PROVIDER_HOME"], "/Users/tester/.future-provider")
        XCTAssertEqual(
            request.environment["TOKSCALE_EXTRA_DIRS"],
            "codex:/Users/tester/more-sessions,claude:relative/sessions,bad-entry"
        )
        XCTAssertEqual(request.environment["XDG_DATA_HOME"], "relative/data")
        XCTAssertEqual(request.environment["KIMI_CODE_HOME"], "/tmp/unsafe\npath")
        XCTAssertEqual(request.environment["TOKSCALE_API_TOKEN"], "secret-token")
        XCTAssertEqual(request.environment["TOKSCALE_DEVICE_ID"], "forced-device")
        XCTAssertEqual(request.environment["TOKSCALE_OTHER"], "other")
        XCTAssertEqual(request.environment["TOKSCALE_FM_DEBUG"], "1")
        XCTAssertEqual(request.environment["TOKSCALE_NATIVE_TIMEOUT_MS"], "600000")
        XCTAssertEqual(request.environment["GH_TOKEN"], "github-secret")
        XCTAssertEqual(request.environment["GITHUB_TOKEN"], "github-secret")
        XCTAssertEqual(request.environment["UNRELATED_SECRET"], "secret")
        XCTAssertEqual(request.environment["BUN_CONFIG_REGISTRY"], "https://registry.example")
        for key in [
            "TOKSCALE_API_URL", "TOKSCALE_FAKE_CODEX_MODE", "NODE_OPTIONS", "BUN_OPTIONS",
            "DYLD_INSERT_LIBRARIES", "LD_LIBRARY_PATH",
        ] {
            XCTAssertNil(request.environment[key], "\(key) must not reach the child")
        }
        XCTAssertEqual(request.currentDirectoryURL?.path, "/Users/tester")
    }

    func testLoginDropsOnlyDeviceNameAndKeepsTokscaleAuthenticationEnvironment() async throws {
        let processRunner = RecordingTokscaleProcessRunner(
            result: StreamingProcessResult(exitCode: 0, output: "logged in")
        )
        let runner = TokscaleCommandRunner(
            processRunner: processRunner,
            inheritedEnvironment: [
                "TOKSCALE_DEVICE_NAME": "ambient-name",
                "TOKSCALE_API_TOKEN": "ambient-token",
                "TOKSCALE_CONFIG_DIR": "/Users/tester/.config/tokscale-custom",
            ],
            loginShellEnvironment: { nil },
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let runtime = BunRuntime(
            bunURL: URL(fileURLWithPath: "/bun"),
            bunxURL: URL(fileURLWithPath: "/bunx"),
            executionPath: "/runtime/bin"
        )

        _ = try await runner.run(.login, runtime: runtime) { _ in }

        let recordedRequest = await processRunner.request()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.arguments, ["tokscale@latest", "login"])
        XCTAssertNil(request.environment["TOKSCALE_DEVICE_NAME"])
        XCTAssertEqual(request.environment["TOKSCALE_API_TOKEN"], "ambient-token")
        XCTAssertEqual(request.environment["TOKSCALE_CONFIG_DIR"], "/Users/tester/.config/tokscale-custom")
    }

    func testSubmitLeavesAmbientDeviceNameForTokscaleToValidateWhenOpenUsageHasNoOverride() async throws {
        let processRunner = RecordingTokscaleProcessRunner(
            result: StreamingProcessResult(exitCode: 0, output: "finished")
        )
        let runner = TokscaleCommandRunner(
            processRunner: processRunner,
            inheritedEnvironment: [:],
            loginShellEnvironment: { ["TOKSCALE_DEVICE_NAME": "  m1-max "] },
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let runtime = BunRuntime(
            bunURL: URL(fileURLWithPath: "/bun"),
            bunxURL: URL(fileURLWithPath: "/bunx"),
            executionPath: "/runtime/bin"
        )

        _ = try await runner.run(.submit(deviceName: nil), runtime: runtime) { _ in }

        let recordedRequest = await processRunner.request()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.environment["TOKSCALE_DEVICE_NAME"], "  m1-max ")
    }

    func testProcessFailurePropagates() async throws {
        let processRunner = RecordingTokscaleProcessRunner(error: TestProcessError.failed)
        let runner = TokscaleCommandRunner(
            processRunner: processRunner,
            inheritedEnvironment: [:],
            loginShellEnvironment: { nil },
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let runtime = BunRuntime(
            bunURL: URL(fileURLWithPath: "/bun"),
            bunxURL: URL(fileURLWithPath: "/bunx"),
            executionPath: "/runtime/bin"
        )

        do {
            _ = try await runner.run(.submit(deviceName: nil), runtime: runtime) { _ in }
            XCTFail("Expected the process error")
        } catch {
            XCTAssertEqual(error as? TestProcessError, .failed)
        }

        let recordedRequest = await processRunner.request()
        XCTAssertEqual(recordedRequest?.currentDirectoryURL?.path, "/Users/tester")
    }

    func testLoginRequiredNeedsExactMarkerAndNonzeroExit() {
        let marker = TokscaleCommandResult.loginRequiredMarker
        XCTAssertTrue(TokscaleCommandResult(exitCode: 1, output: marker).requiresLogin)
        XCTAssertFalse(TokscaleCommandResult(exitCode: 0, output: marker).requiresLogin)
        XCTAssertFalse(
            TokscaleCommandResult(exitCode: 1, output: "Run 'bunx tokscale@latest login'.").requiresLogin
        )
        XCTAssertFalse(
            TokscaleCommandResult(exitCode: 1, output: marker.lowercased()).requiresLogin
        )
    }

    func testLoginRequiredMarkerIsDetectedAcrossChunksOutsideBoundedResult() async throws {
        let marker = TokscaleCommandResult.loginRequiredMarker
        let processRunner = RecordingTokscaleProcessRunner(
            result: StreamingProcessResult(exitCode: 1, output: "bounded tail"),
            output: [
                String(marker.prefix(5)),
                String(marker.dropFirst(5)),
            ]
        )
        let runner = TokscaleCommandRunner(
            processRunner: processRunner,
            inheritedEnvironment: [:],
            loginShellEnvironment: { nil },
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        )
        let runtime = BunRuntime(
            bunURL: URL(fileURLWithPath: "/bun"),
            bunxURL: URL(fileURLWithPath: "/bunx"),
            executionPath: "/runtime/bin"
        )

        let result = try await runner.run(.submit(deviceName: nil), runtime: runtime) { _ in }

        XCTAssertEqual(result.output, "bounded tail")
        XCTAssertTrue(result.requiresLogin)
    }

}

private enum TestProcessError: Error, Equatable {
    case failed
}

private actor RecordingTokscaleProcessRunner: StreamingProcessRunning {
    private let result: StreamingProcessResult?
    private let error: TestProcessError?
    private let output: [String]
    private var recordedRequest: StreamingProcessRequest?

    init(result: StreamingProcessResult, output: [String] = ["live"]) {
        self.result = result
        self.error = nil
        self.output = output
    }

    init(error: TestProcessError) {
        self.result = nil
        self.error = error
        self.output = ["live"]
    }

    func run(
        _ request: StreamingProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult {
        recordedRequest = request
        for chunk in output { onOutput(chunk) }
        if let error { throw error }
        return result ?? StreamingProcessResult(exitCode: 1, output: "")
    }

    func request() -> StreamingProcessRequest? {
        recordedRequest
    }
}
