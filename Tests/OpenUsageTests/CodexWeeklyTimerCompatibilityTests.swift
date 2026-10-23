import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerCompatibilityTests: XCTestCase {
    func testOlderCLIRevalidatesBeforeWritingAuthAndUsesTheValidatedConfiguration() async throws {
        let fixture = try CompatibilityFixture(preflight: """
        for argument in "$@"; do
          if [ "$argument" = 'features.daemon_auto_start=false' ]; then
            printf '%s\\n' '\(Self.unsupportedDaemonSetting)' >&2
            exit 1
          fi
        done
        exit 0
        """, message: """
        for argument in "$@"; do
          if [ "$argument" = 'features.daemon_auto_start=false' ]; then exit 91; fi
        done
        printf '%s\\n' '{"type":"turn.completed"}'
        """)
        defer { fixture.remove() }

        let result = await fixture.executor.execute(auth: Self.auth)

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.completed)
        XCTAssertNil(result.failureDescription)
        let checks = try fixture.preflightArguments()
        XCTAssertEqual(checks.count, 2)
        let firstCheck = try XCTUnwrap(checks.first)
        let retryCheck = try XCTUnwrap(checks.dropFirst().first)
        XCTAssertTrue(firstCheck.contains("features.daemon_auto_start=false"))
        var expected = firstCheck
        let settingIndex = try XCTUnwrap(expected.firstIndex(of: "features.daemon_auto_start=false"))
        expected.removeSubrange((settingIndex - 1)...settingIndex)
        XCTAssertEqual(retryCheck, expected)
        for check in checks {
            XCTAssertTrue(check.contains("--strict-config"))
            XCTAssertTrue(check.contains("features.shell_tool=false"))
            XCTAssertTrue(check.contains("features.skip_host_skill_discovery=true"))
        }
        let message = try fixture.messageArguments()
        XCTAssertEqual(Array(message.drop { $0 != "-c" }.dropLast()), Array(retryCheck.dropFirst(3)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testCurrentCLIKeepsDaemonDisabledWithoutRetry() async throws {
        let fixture = try CompatibilityFixture(preflight: "exit 0", message: """
        for argument in "$@"; do
          if [ "$argument" = 'features.daemon_auto_start=false' ]; then
            printf '%s\\n' '{"type":"turn.completed"}'
            exit 0
          fi
        done
        exit 92
        """)
        defer { fixture.remove() }

        let result = await fixture.executor.execute(auth: Self.auth)

        XCTAssertTrue(result.completed)
        XCTAssertEqual(try fixture.preflightArguments().count, 1)
        XCTAssertTrue(try fixture.messageArguments().contains("features.daemon_auto_start=false"))
    }

    func testOtherConfigurationErrorsNeverRelaxIsolation() async throws {
        for diagnostic in [
            "Error: unknown configuration field `features.skip_host_skill_discovery` in -c/--config override",
            "Error: unknown configuration field `features.unknown_feature` in -c/--config override",
            Self.unsupportedDaemonSetting + "\nError: another configuration failed",
        ] {
            let fixture = try CompatibilityFixture(preflight: "printf '%s\\n' '\(diagnostic)' >&2\nexit 1")
            defer { fixture.remove() }

            let result = await fixture.executor.execute(auth: Self.auth)
            let context = "Diagnostic: \(diagnostic); failure: \(result.failureDescription ?? "none"); processes: \(fixture.processTrace)"

            XCTAssertFalse(result.launched, context)
            XCTAssertFalse(result.completed, context)
            let preflights = try? fixture.preflightArguments()
            XCTAssertNotNil(preflights, context)
            XCTAssertEqual(preflights?.count, 1, context)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.messageLog.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
        }
    }

    func testMatchingStdoutCannotTriggerCompatibilityRetry() async throws {
        let fixture = try CompatibilityFixture(preflight: "printf '%s\\n' '\(Self.unsupportedDaemonSetting)'\nexit 1")
        defer { fixture.remove() }

        let result = await fixture.executor.execute(auth: Self.auth)

        XCTAssertFalse(result.launched)
        XCTAssertEqual(try fixture.preflightArguments().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.messageLog.path))
    }

    func testCompatibilityRetryStillFailsClosedAndRunsOnlyOnce() async throws {
        let fixture = try CompatibilityFixture(preflight: "printf '%s\\n' '\(Self.unsupportedDaemonSetting)' >&2\nexit 1")
        defer { fixture.remove() }

        let result = await fixture.executor.execute(auth: Self.auth)

        XCTAssertFalse(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(try fixture.preflightArguments().count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.messageLog.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    private static let unsupportedDaemonSetting =
        "Error: unknown configuration field `features.daemon_auto_start` in -c/--config override"
    private static let auth = CodexAuth(tokens: CodexTokens(
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        idToken: "synthetic-id", accountID: "synthetic-account"
    ))
}

@MainActor
private struct CompatibilityFixture {
    let root: URL
    let executable: URL
    private let processRunner = CompatibilityProcessRunner()
    var workspaceRoot: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    var messageLog: URL { executable.appendingPathExtension("message") }
    var processTrace: [String] { processRunner.trace }
    var executor: CodexWeeklyTimerExecutor {
        CodexWeeklyTimerExecutor(processRunner: processRunner, executableResolver: { executable }, baseDirectory: workspaceRoot)
    }

    init(preflight: String, message: String = "exit 93") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenUsage.TimerCompatibility.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("fake-codex")
        let source = """
        #!/bin/sh
        if [ "$1" = "exec" ] && [ "$2" = "--help" ]; then
          printf '%s\\n' '--json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check'
          exit 0
        fi
        if [ "$1" = "app-server" ]; then
          [ ! -e "$CODEX_HOME/auth.json" ] || exit 94
          printf '%s\\n' PRECHECK "$@" >> "$0.preflights"
          \(preflight)
        fi
        printf '%s\\n' "$@" > "$0.message"
        \(message)
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func preflightArguments() throws -> [[String]] {
        try String(contentsOf: executable.appendingPathExtension("preflights"), encoding: .utf8)
            .components(separatedBy: "PRECHECK\n").dropFirst().map {
                $0.split(separator: "\n").map(String.init)
            }
    }

    func messageArguments() throws -> [String] {
        try String(contentsOf: messageLog, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private final class CompatibilityProcessRunner: StreamingProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var trace: [String] { lock.withLock { events } }

    func run(
        _ request: StreamingProcessRequest, onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult {
        try await run(request, onLaunch: {}, onOutput: onOutput)
    }

    func run(
        _ request: StreamingProcessRequest,
        onLaunch: @escaping @Sendable () -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult {
        let command = request.arguments.prefix(2).joined(separator: " ")
        let started = Date()
        do {
            let result = try await StreamingProcessRunner().run(request, onLaunch: {
                self.lock.withLock { self.events.append("\(command): launched") }
                onLaunch()
            }, onOutput: onOutput)
            lock.withLock {
                events.append("\(command): exit \(result.exitCode), \(Date().timeIntervalSince(started))s, stdout \(result.output.count) chars, stderr \(result.standardError)")
            }
            return result
        } catch {
            lock.withLock { events.append("\(command): \(error), \(Date().timeIntervalSince(started))s") }
            throw error
        }
    }
}
