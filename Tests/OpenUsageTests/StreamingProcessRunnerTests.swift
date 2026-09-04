import Darwin
import Foundation
import XCTest
@testable import OpenUsage

final class StreamingProcessRunnerTests: XCTestCase {
    func testRejectsNonFileExecutableURL() async {
        let request = makeRequest(executableURL: URL(string: "bin/echo")!)

        do {
            _ = try await StreamingProcessRunner().run(request)
            XCTFail("A non-file executable URL must not launch")
        } catch let error as StreamingProcessRunnerError {
            XCTAssertEqual(error, .executableMustBeAbsolute)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUsesOnlyTheExplicitEnvironment() async throws {
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            environment: ["OPENUSAGE_ONLY": "present"]
        )

        let result = try await StreamingProcessRunner().run(request)
        let lines = Set(result.output.split(whereSeparator: \.isNewline).map(String.init))

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(lines.contains("OPENUSAGE_ONLY=present"))
        XCTAssertFalse(lines.contains { $0.hasPrefix("HOME=") })
        XCTAssertFalse(lines.contains { $0.hasPrefix("PATH=") })
    }

    func testUsesWorkingDirectoryAndNullStandardInput() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.StreamingRunner.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = makeRequest(
            arguments: ["-c", "if read value; then printf input; else pwd; fi"],
            currentDirectoryURL: directory
        )
        let result = try await StreamingProcessRunner().run(request)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), directory.path)
    }

    func testDrainsStdoutAndStderrWhileBoundingRetainedOutput() async throws {
        let chunks = LockedText()
        let request = makeRequest(
            arguments: [
                "-c",
                "i=0; while [ $i -lt 5000 ]; do printf o; printf e >&2; i=$((i + 1)); done",
            ],
            outputLimit: 128
        )

        let result = try await StreamingProcessRunner().run(request) { chunk in
            chunks.append(chunk)
        }

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 128)
        XCTAssertTrue(chunks.value.contains("o"))
        XCTAssertTrue(chunks.value.contains("e"))
        XCTAssertEqual(chunks.value.count, 10_000)
    }

    func testRetainedOutputDoesNotSplitUTF8Scalars() async throws {
        let request = makeRequest(
            arguments: ["-c", "printf '1234567890🙂'"],
            outputLimit: 8
        )

        let result = try await StreamingProcessRunner().run(request)

        XCTAssertEqual(result.output, "1234🙂")
        XCTAssertEqual(result.output.utf8.count, 8)
    }

    func testSanitizerRemovesCSIOSCAndUnsafeControls() {
        let input = "\u{1B}[31mCODE-AB12\u{1B}[0m\n"
            + "\u{1B}]8;;https://hidden.example\u{07}https://tokscale.com/u/test\u{1B}]8;;\u{07}"
            + "\u{00}\u{08}\t"

        XCTAssertEqual(
            TerminalOutputSanitizer.sanitize(input),
            "CODE-AB12\nhttps://tokscale.com/u/test\t"
        )
    }

    func testSanitizerCarriesEscapeStateAcrossChunks() {
        var sanitizer = TerminalOutputSanitizer()

        XCTAssertEqual(sanitizer.append("\u{1B}["), "")
        XCTAssertEqual(sanitizer.append("32mhttps://tokscale.com/verify "), "https://tokscale.com/verify ")
        XCTAssertEqual(sanitizer.append("USER-CODE\u{1B}]0;secret"), "USER-CODE")
        XCTAssertEqual(sanitizer.append(" title\u{1B}\\done"), "done")
        XCTAssertEqual(sanitizer.finish(), "")
    }

    func testTimeoutTerminatesDescendantProcess() async throws {
        let capture = PIDCapture()
        let request = longRunningChildRequest(timeout: 0.25)

        do {
            _ = try await StreamingProcessRunner().run(request) { capture.append($0) }
            XCTFail("The command must time out")
        } catch let error as StreamingProcessRunnerError {
            XCTAssertEqual(error, .timedOut(timeout: 0.25))
        }

        let childPID = try XCTUnwrap(capture.capturedPID)
        await assertProcessIsGone(childPID)
    }

    func testNaturalParentExitTerminatesSameGroupChildThatHoldsPipes() async throws {
        let capture = PIDCapture()
        let request = makeRequest(
            arguments: [
                "-c",
                "(trap '' TERM; /bin/sleep 30) & child=$!; printf '%s\\n' $child; exit 0",
            ]
        )

        let result = try await StreamingProcessRunner().run(request) { capture.append($0) }

        XCTAssertEqual(result.exitCode, 0)
        let childPID = try XCTUnwrap(capture.capturedPID)
        await assertProcessIsGone(childPID)
    }

    func testNaturalParentExitTerminatesSameGroupChildThatClosedItsPipes() async throws {
        let capture = PIDCapture()
        let request = makeRequest(
            arguments: [
                "-c",
                "(exec >/dev/null 2>&1; /bin/sleep 30) & child=$!; printf '%s\\n' $child; exit 0",
            ]
        )

        let result = try await StreamingProcessRunner().run(request) { capture.append($0) }

        XCTAssertEqual(result.exitCode, 0)
        let childPID = try XCTUnwrap(capture.capturedPID)
        await assertProcessIsGone(childPID)
    }

    func testCancellationTerminatesDescendantProcess() async throws {
        let capture = PIDCapture()
        let request = longRunningChildRequest(timeout: 30)
        let task = Task {
            try await StreamingProcessRunner().run(request) { capture.append($0) }
        }

        let childPID = await capture.waitForPID()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must be propagated")
        } catch is CancellationError {
            // 예상된 취소.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        await assertProcessIsGone(childPID)
    }

    func testCancellationStillStopsDrainsAfterOriginalProcessGroupCompletes() {
        let cleanup = LockedFlag()
        let termination = ProcessTerminationController {
            cleanup.set()
        }
        termination.didLaunch(processGroupID: 2_000_000_000)
        termination.didCompleteNaturally()

        termination.requestTermination()

        XCTAssertTrue(cleanup.value)
    }

    func testLogsOnlyExecutableNameArgumentCountAndExit() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.StreamingRunnerLog.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.debug)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        let argumentCanary = "argument-canary-48291"
        let environmentCanary = "environment-canary-59302"
        let request = makeRequest(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: [argumentCanary],
            environment: ["CANARY": environmentCanary]
        )

        _ = try await StreamingProcessRunner().run(request)
        let log = try String(
            contentsOf: directory.appendingPathComponent("OpenUsage.log"),
            encoding: .utf8
        )

        XCTAssertTrue(log.contains("[subprocess] launch echo (1 args)"), log)
        XCTAssertTrue(log.contains("[subprocess] exit 0"), log)
        XCTAssertFalse(log.contains(argumentCanary), log)
        XCTAssertFalse(log.contains(environmentCanary), log)
    }

    private func makeRequest(
        executableURL: URL = URL(fileURLWithPath: "/bin/sh"),
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 5,
        outputLimit: Int = 16_384
    ) -> StreamingProcessRequest {
        StreamingProcessRequest(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL,
            timeout: timeout,
            outputLimit: outputLimit
        )
    }

    private func longRunningChildRequest(timeout: TimeInterval) -> StreamingProcessRequest {
        makeRequest(
            arguments: [
                "-c",
                "trap '' TERM; /bin/sleep 30 & child=$!; printf '%s\\n' $child; wait $child",
            ],
            timeout: timeout
        )
    }

    private func assertProcessIsGone(_ pid: pid_t) async {
        for _ in 0 ..< 100 {
            errno = 0
            if Darwin.kill(pid, 0) == -1, errno == ESRCH {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Descendant process \(pid) is still alive")
    }
}

private final class LockedText: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage.append(text)
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    func set() {
        lock.lock()
        storage = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class PIDCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var pid: pid_t?
    private var waiters: [CheckedContinuation<pid_t, Never>] = []

    func append(_ chunk: String) {
        lock.lock()
        text.append(chunk)
        if pid == nil,
           let line = text.split(whereSeparator: \.isNewline).first,
           let parsed = pid_t(line) {
            pid = parsed
            let waiters = self.waiters
            self.waiters.removeAll()
            lock.unlock()
            for waiter in waiters {
                waiter.resume(returning: parsed)
            }
            return
        }
        lock.unlock()
    }

    var capturedPID: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return pid
    }

    func waitForPID() async -> pid_t {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let pid {
                lock.unlock()
                continuation.resume(returning: pid)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
