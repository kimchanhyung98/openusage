import Darwin
import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerExecutorTests: XCTestCase {
    func testUsesPrivateSubscriptionAuthAndClearsWorkspaceAfterSuccess() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = RecordingTimerRunner { request, output in
            let environment = request.environment
            let codexHome = try XCTUnwrap(environment["CODEX_HOME"])
            let authURL = URL(fileURLWithPath: codexHome).appendingPathComponent("auth.json")
            let auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: authURL))
            XCTAssertEqual(auth.tokens?.accessToken, "original-access")
            XCTAssertNil(auth.apiKey)
            XCTAssertNil(environment["OPENAI_API_KEY"])
            XCTAssertNil(environment["CODEX_ACCESS_TOKEN"])
            XCTAssertNil(environment["CODEX_API_KEY"])
            XCTAssertNil(environment["RUST_LOG"])
            XCTAssertEqual(try permissions(authURL), 0o600)
            XCTAssertEqual(try permissions(URL(fileURLWithPath: codexHome)), 0o700)
            XCTAssertNotEqual(environment["HOME"], NSHomeDirectory())
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(
                atPath: XCTUnwrap(request.currentDirectoryURL?.path)
            ), [])
            XCTAssertEqual(String(data: request.standardInput, encoding: .utf8), CodexWeeklyTimerExecutorTests.prompt + "\n")
            XCTAssertEqual(request.timeout, 60)
            XCTAssertTrue(request.captureStandardErrorSeparately)
            XCTAssertEqual(request.outputLimit, 0)
            output("{\"type\":\"turn.")
            output("completed\",\"usage\":{}}\n")
            return StreamingProcessResult(exitCode: 0, output: "")
        }
        var auth = Self.auth
        auth.apiKey = "stale-api-key-that-must-not-be-used"
        let result = await fixture.executor(runner: runner).execute(auth: auth)

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.completed)
        XCTAssertNil(result.updatedAuth)
        XCTAssertNil(result.failureDescription)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
        XCTAssertEqual(runner.requests.count, 3)
        let message = try XCTUnwrap(runner.requests.last)
        for argument in ["--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "read-only", "--skip-git-repo-check"] {
            XCTAssertTrue(message.arguments.contains(argument))
        }
        XCTAssertTrue(message.arguments.contains("features.shell_tool=false"))
        XCTAssertTrue(message.arguments.contains("features.apps=false"))
        XCTAssertTrue(message.arguments.contains("cli_auth_credentials_store=\"file\""))
    }

    func testRequiresCompletedEventAndSuccessfulExit() async throws {
        for (events, exitCode, completed) in [
            ("{\"type\":\"thread.started\"}\n{\"type\":\"turn.started\"}\n", Int32(0), false),
            ("{\"type\":\"turn.completed\"}\n", Int32(7), false),
            ("{\"type\":\"turn.failed\"}\n{\"type\":\"turn.completed\"}\n", Int32(0), false),
            ("{\"type\":\"turn.completed\"}", Int32(0), true),
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let runner = RecordingTimerRunner { _, output in
                output(events)
                return StreamingProcessResult(exitCode: exitCode, output: "")
            }
            let result = await fixture.executor(runner: runner).execute(auth: Self.auth)
            XCTAssertTrue(result.launched)
            XCTAssertEqual(result.completed, completed)
        }
    }

    func testCompletedMessageRemainsCompletedWhenReadingRotatedAuthFails() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = RecordingTimerRunner { request, output in
            let home = try XCTUnwrap(request.environment["CODEX_HOME"])
            try Data("invalid-auth".utf8).write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
            output("{\"type\":\"turn.completed\"}\n")
            return StreamingProcessResult(exitCode: 0, output: "")
        }

        let result = await fixture.executor(runner: runner).execute(auth: Self.auth)

        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.failureDescription, "Codex weekly timer credentials could not be read after the message.")
        XCTAssertFalse(result.verificationCanClearFailure)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.weeklyTimer, result: .failure, category: .decoding, providerID: "codex")
        ])
    }

    func testMissingExecutableAndIncompatibleCLIProveNoMessageLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missing = CodexWeeklyTimerExecutor(executableResolver: { nil }, baseDirectory: fixture.workspaceRoot)
        let missingResult = await missing.execute(auth: Self.auth)
        XCTAssertFalse(missingResult.launched)
        let runner = RecordingTimerRunner(supportsRequiredFlags: false) { _, _ in
            XCTFail("An incompatible CLI must not send a message")
            return StreamingProcessResult(exitCode: 0, output: "")
        }
        let incompatible = await fixture.executor(runner: runner).execute(auth: Self.auth)
        XCTAssertFalse(incompatible.launched)
        XCTAssertEqual(runner.requests.count, 1)
    }

    func testRunFailureIsPreservedWhenReadingRotatedAuthAlsoFails() async throws {
        for (outcome, expected) in [
            (0, "Codex weekly timer message timed out."),
            (1, "Codex weekly timer message was cancelled."),
            (2, "Codex weekly timer message did not complete."),
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let runner = RecordingTimerRunner { request, _ in
                let home = try XCTUnwrap(request.environment["CODEX_HOME"])
                try Data("invalid-auth".utf8).write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
                if outcome == 0 { throw StreamingProcessRunnerError.timedOut(timeout: 60) }
                if outcome == 1 { throw CancellationError() }
                return StreamingProcessResult(exitCode: 1, output: "")
            }
            let result = await fixture.executor(runner: runner).execute(auth: Self.auth)

            XCTAssertTrue(result.launched)
            XCTAssertFalse(result.completed)
            XCTAssertEqual(result.failureDescription, expected)
            XCTAssertFalse(result.verificationCanClearFailure)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
        }
    }

    func testIncompleteCLIAuthIsNeverReturnedForWriteback() async throws {
        let fields: [WritableKeyPath<CodexTokens, String?>] = [\.accessToken, \.refreshToken, \.idToken]
        for field in fields {
            for value: String? in [nil, ""] {
                for outcome in 0..<3 {
                    let fixture = try Fixture()
                    defer { fixture.remove() }
                    var incomplete = Self.auth
                    incomplete.tokens?[keyPath: field] = value
                    let data = try JSONEncoder().encode(incomplete)
                    let runner = RecordingTimerRunner { request, output in
                        let home = try XCTUnwrap(request.environment["CODEX_HOME"])
                        try data.write(to: URL(fileURLWithPath: home).appendingPathComponent("auth.json"))
                        if outcome == 1 { throw StreamingProcessRunnerError.timedOut(timeout: 60) }
                        if outcome == 2 { throw CancellationError() }
                        output("{\"type\":\"turn.completed\"}\n")
                        return StreamingProcessResult(exitCode: 0, output: "")
                    }
                    let result = await fixture.executor(runner: runner).execute(auth: Self.auth)

                    XCTAssertTrue(result.launched)
                    XCTAssertEqual(result.completed, outcome == 0)
                    XCTAssertNil(result.updatedAuth)
                    XCTAssertFalse(result.verificationCanClearFailure)
                    XCTAssertNotNil(result.failureDescription)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
                }
            }
        }
    }

    func testIncompleteSubscriptionAuthFailsBeforeInvokingCLI() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = RecordingTimerRunner { _, _ in
            XCTFail("Incomplete subscription auth must not launch")
            return StreamingProcessResult(exitCode: 0, output: "")
        }
        var auth = Self.auth
        auth.tokens?.idToken = nil
        let result = await fixture.executor(runner: runner).execute(auth: auth)
        XCTAssertFalse(result.launched)
        XCTAssertTrue(runner.requests.isEmpty)
    }

    func testRevalidatesAccountAfterCapabilitiesWithoutLaunchingMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = RecordingTimerRunner { _, _ in
            XCTFail("The invalidated account must not launch")
            return StreamingProcessResult(exitCode: 0, output: "")
        }
        let result = await fixture.executor(runner: runner).execute(auth: Self.auth, canLaunch: { false })
        XCTAssertFalse(result.launched)
        XCTAssertEqual(runner.requests.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testSpawnFailureAfterCapabilitiesStillProvesNoMessageLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let result = await fixture.executor().execute(auth: Self.auth, canLaunch: {
            try? FileManager.default.removeItem(at: fixture.executable)
            return true
        })
        XCTAssertFalse(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failureDescription, "Codex weekly timer message failed.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testReturnsRefreshedAuthEvenAfterTimeoutAndNeverLeaksOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = RecordingTimerRunner { request, output in
            let authURL = URL(fileURLWithPath: try XCTUnwrap(request.environment["CODEX_HOME"]))
                .appendingPathComponent("auth.json")
            var auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: authURL))
            auth.tokens?.accessToken = "updated-access"
            auth.tokens?.refreshToken = "updated-refresh"
            try JSONEncoder().encode(auth).write(to: authURL)
            output("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"secret-model-answer\"}}\n")
            throw StreamingProcessRunnerError.timedOut(timeout: 60)
        }
        let result = await fixture.executor(runner: runner).execute(auth: Self.auth)
        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.updatedAuth?.tokens?.accessToken, "updated-access")
        XCTAssertEqual(result.updatedAuth?.tokens?.refreshToken, "updated-refresh")
        XCTAssertEqual(result.failureDescription, "Codex weekly timer message timed out.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testFakeCLIStderrCannotForgeSuccessfulCompletion() async throws {
        let fixture = try Fixture(script: "printf '%s\\n' '{\"type\":\"turn.completed\"}' >&2\nexit 0")
        defer { fixture.remove() }
        let result = await fixture.executor().execute(auth: Self.auth)
        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.completed)
    }

    func testFakeCLIStdoutCompletionSucceedsDespiteStderrNoise() async throws {
        let fixture = try Fixture(script: "printf '%s\\n' 'stderr-secret' >&2\nprintf '%s\\n' '{\"type\":\"turn.completed\"}'")
        defer { fixture.remove() }
        let result = await fixture.executor().execute(auth: Self.auth)
        XCTAssertTrue(result.completed)
        XCTAssertNil(result.failureDescription)
    }

    func testStartupWarningItemsDoNotCancelSuccessfulTurn() async throws {
        let fixture = try Fixture(script: """
        printf '%s\\n' \
          '{"type":"item.completed","item":{"type":"error","message":"Under-development features enabled: skip_host_skill_discovery."}}' \
          '{"type":"item.completed","item":{"type":"error","message":"Code Mode is unavailable because code-mode host is disabled."}}' \
          '{"type":"turn.started"}' \
          '{"type":"item.completed","item":{"type":"agent_message","text":"I do not know."}}' \
          '{"type":"turn.completed","usage":{}}'
        """)
        defer { fixture.remove() }

        let result = await fixture.executor().execute(auth: Self.auth)

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.completed)
        XCTAssertNil(result.failureDescription)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testWarningItemsDoNotHideTerminalErrors() async throws {
        for terminal in ["error", "turn.failed"] {
            let fixture = try Fixture(script: """
            printf '%s\\n' \
              '{"type":"item.completed","item":{"type":"error","message":"Startup warning."}}' \
              '{"type":"\(terminal)","message":"Request failed."}' \
              '{"type":"turn.completed","usage":{}}'
            """)
            defer { fixture.remove() }

            let result = await fixture.executor().execute(auth: Self.auth)

            XCTAssertTrue(result.launched)
            XCTAssertFalse(result.completed)
            XCTAssertEqual(result.failureDescription, "Codex weekly timer message did not complete.")
        }
    }

    func testTimeoutTerminatesFakeCLIAndCleansAuth() async throws {
        let fixture = try Fixture(script: "/bin/sleep 30")
        defer { fixture.remove() }
        let result = await fixture.executor(timeout: 0.1).execute(auth: Self.auth)
        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failureDescription, "Codex weekly timer message timed out.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testUnexpectedToolEventCancelsFakeCLI() async throws {
        let fixture = try Fixture(script: "printf '%s\\n' '{\"type\":\"item.started\",\"item\":{\"type\":\"command_execution\"}}'\n/bin/sleep 30")
        defer { fixture.remove() }
        let result = await fixture.executor(timeout: 5).execute(auth: Self.auth)
        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failureDescription, "Codex weekly timer stopped an unexpected tool or invalid response.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testCancellationCleansUpTemporaryCredentials() async throws {
        let fixture = try Fixture(script: "printf '%s\\n' '{\"type\":\"turn.started\"}'\n/bin/sleep 30")
        defer { fixture.remove() }
        let executor = fixture.executor()
        let task = Task { await executor.execute(auth: Self.auth) }
        do {
            try await fixture.waitForMessageStart()
        } catch {
            task.cancel()
            _ = await task.value
            throw error
        }
        task.cancel()
        let result = await task.value
        XCTAssertTrue(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertEqual(result.failureDescription, "Codex weekly timer message was cancelled.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.workspaceRoot.path), [])
    }

    func testWorkspaceRejectsSymlinkRootAndPreservesUnrelatedPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let actual = fixture.root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.workspaceRoot, withDestinationURL: actual)
        XCTAssertThrowsError(try CodexWeeklyTimerWorkspace(baseDirectory: fixture.workspaceRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: actual.path))
    }

    func testWorkspaceRemovesOnlyDeadProcessDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.workspaceRoot, withIntermediateDirectories: true)
        let dead = fixture.workspaceRoot.appendingPathComponent("session-2147483647-\(UUID().uuidString)")
        let active = fixture.workspaceRoot.appendingPathComponent("session-\(getpid())-\(UUID().uuidString)")
        let other = fixture.workspaceRoot.appendingPathComponent("unrelated")
        for url in [dead, active, other] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let workspace = try CodexWeeklyTimerWorkspace(baseDirectory: fixture.workspaceRoot)
        defer { try? workspace.remove() }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testAbandonedWorkspaceDoesNotSurviveBecauseItsPIDIsStillAlive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var abandoned: CodexWeeklyTimerWorkspace? = try CodexWeeklyTimerWorkspace(baseDirectory: fixture.workspaceRoot)
        let abandonedDirectory = try XCTUnwrap(abandoned?.directory)
        try abandoned?.writeAuth(Self.auth)
        abandoned = nil
        let active = try CodexWeeklyTimerWorkspace(baseDirectory: fixture.workspaceRoot)
        defer { try? active.remove() }

        try CodexWeeklyTimerWorkspace.cleanAbandonedWorkspaces(baseDirectory: fixture.workspaceRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.directory.path))
    }

    nonisolated private static let prompt = "When does my weekly Codex usage limit reset? Answer briefly without using tools."
    private static let auth = CodexAuth(tokens: CodexTokens(
        accessToken: "original-access", refreshToken: "original-refresh",
        idToken: "original-id", accountID: "account"
    ))
}

@MainActor
private struct Fixture {
    let root: URL
    let executable: URL
    var workspaceRoot: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    var messageStartedURL: URL { executable.appendingPathExtension("started") }

    init(script: String = "exit 1") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenUsage.TimerExecutorTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("fake-codex")
        let source = """
        #!/bin/sh
        if [ "$1" = "exec" ] && [ "$2" = "--help" ]; then
          printf '%s\\n' '--json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check'
          exit 0
        fi
        if [ "$1" = "app-server" ]; then exit 0; fi
        : > "$0.started"
        \(script)
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func executor(runner: any StreamingProcessRunning = StreamingProcessRunner(), timeout: TimeInterval = 60) -> CodexWeeklyTimerExecutor {
        CodexWeeklyTimerExecutor(
            processRunner: runner, executableResolver: { executable }, baseDirectory: workspaceRoot, timeout: timeout
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func waitForMessageStart() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: messageStartedURL.path) {
            guard clock.now < deadline else { throw StartupError.messageDidNotStart }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private enum StartupError: Error { case messageDidNotStart }
}

private final class RecordingTimerRunner: StreamingProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [StreamingProcessRequest] = []
    private let supportsRequiredFlags: Bool
    private let message: @Sendable (StreamingProcessRequest, @Sendable (String) -> Void) throws -> StreamingProcessResult

    init(
        supportsRequiredFlags: Bool = true,
        message: @escaping @Sendable (StreamingProcessRequest, @Sendable (String) -> Void) throws -> StreamingProcessResult
    ) {
        self.supportsRequiredFlags = supportsRequiredFlags
        self.message = message
    }

    var requests: [StreamingProcessRequest] { lock.withLock { captured } }

    func run(_ request: StreamingProcessRequest, onOutput: @escaping @Sendable (String) -> Void) async throws -> StreamingProcessResult {
        lock.withLock { captured.append(request) }
        if request.arguments == ["exec", "--help"] {
            return StreamingProcessResult(
                exitCode: 0,
                output: supportsRequiredFlags ? "--json --ephemeral --ignore-user-config --ignore-rules --skip-git-repo-check" : "--json"
            )
        }
        if request.arguments.first == "app-server" { return StreamingProcessResult(exitCode: 0, output: "") }
        return try message(request, onOutput)
    }
}

private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
}
