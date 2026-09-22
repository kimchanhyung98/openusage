import XCTest

@testable import OpenUsage

final class ProcessRunnerTests: XCTestCase {
    /// OS pipe buffer(~64KB) 초과 출력을 동시 drain해 child write deadlock 방지
    func testLargeStdoutDoesNotDeadlock() throws {
        let runner = SystemProcessRunner()
        let result = try runner.run(
            executable: "/bin/sh",
            arguments: ["-c", "yes 0123456789 | head -c 200000"],
            environment: [:],
            timeout: 10
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 200_000)
    }

    func testCapturesStdoutAndExitCode() throws {
        let runner = SystemProcessRunner()
        let result = try runner.run(executable: "/bin/echo", arguments: ["hello"], environment: [:], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testStandardInputPreservesBytesAndClosesAtEnd() throws {
        let input = String(repeating: "입력\0'\"\\\n", count: 250)
        let result = try SystemProcessRunner().run(
            executable: "/bin/cat", arguments: [], environment: [:], timeout: 5,
            standardInput: Data(input.utf8)
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, input)
    }

    func testStandardInputSupportsEmptyInputAndFullSecurityCommand() throws {
        for count in [0, 4_095, 4_096] {
            let result = try SystemProcessRunner().run(
                executable: "/bin/cat", arguments: [], environment: [:], timeout: 5,
                standardInput: Data(repeating: 65, count: count)
            )
            XCTAssertTrue(result.succeeded)
            XCTAssertEqual(result.stdout, String(repeating: "A", count: count))
        }
    }

    func testEarlyExitWithoutReadingInputPreservesExitCode() throws {
        let result = try SystemProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "exec 0<&-; exit 7"], environment: [:], timeout: 5,
            standardInput: Data(repeating: 65, count: 4_096)
        )
        XCTAssertEqual(result.exitCode, 7)
    }

    func testUnreadStandardInputDoesNotBlockTimeout() {
        let started = Date()
        XCTAssertThrowsError(
            try SystemProcessRunner().run(
                executable: "/bin/sleep", arguments: ["30"], environment: [:], timeout: 0.1,
                standardInput: Data(repeating: 65, count: 4_096)
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunnerError, .timedOut(executable: "/bin/sleep", timeout: 0.1))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testLegacyRunnerRejectsInputInsteadOfSilentlyDiscardingIt() {
        struct LegacyRunner: ProcessRunning {
            func run(
                executable: String, arguments: [String], environment: [String: String],
                timeout: TimeInterval
            ) throws -> ProcessResult {
                ProcessResult(exitCode: 0, stdout: "", stderr: "")
            }
        }
        XCTAssertThrowsError(
            try LegacyRunner().run(
                executable: "/bin/cat", arguments: [], environment: [:], timeout: 5, standardInput: Data()
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunnerError, .standardInputUnsupported)
        }
    }

    func testOversizedInputIsRejectedBeforeStartingDescendants() {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let started = Date()
        for count in [4_097, 1_000_000] {
            XCTAssertThrowsError(
                try SystemProcessRunner().run(
                    executable: "/bin/sh",
                    arguments: ["-c", "exec 3<&0; /bin/sleep 1 <&3 >/dev/null 2>&1 & /usr/bin/touch \"$1\"", "_", marker.path],
                    environment: [:], timeout: 0.1,
                    standardInput: Data(repeating: 65, count: count)
                )
            ) { error in
                XCTAssertEqual(error as? ProcessRunnerError, .standardInputTooLarge)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
}
