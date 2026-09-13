import Darwin
import XCTest
@testable import OpenUsage

@MainActor
final class CodexSoftLimitTerminalFixtureTests: XCTestCase {
    func testFixturePropagatesChildExitAndSignalFailures() async throws {
        for (script, expected) in [("exit 0", Int32(0)), ("exit 23", 23), ("kill -TERM $$", 1)] {
            try await withStub(script) { process, _ in
                try await waitForExit(process)
                XCTAssertEqual(process.terminationReason, .exit)
                XCTAssertEqual(process.terminationStatus, expected)
            }
        }
    }

    func testFixtureTerminationStopsItsSpawnedChild() async throws {
        try await withStub("exec /bin/sleep 60") { process, directory in
            let ready = directory.appendingPathComponent("terminal.pid")
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: ready.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pid = try XCTUnwrap(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), 0)
            process.terminate()
            try await waitForExit(process)
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
    }

    private func withStub(
        _ script: String,
        verify: (Process, URL) async throws -> Void
    ) async throws {
        let directory = URL(fileURLWithPath: "/tmp/openusage-soft-limit-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("Fixture cleanup failed: \(error)") }
        }
        let stub = directory.appendingPathComponent("codex")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = [root.appendingPathComponent("script/fixtures/codex_soft_limit_terminal.exp").path,
                             directory.path, directory.appendingPathComponent("unused.sock").path,
                             directory.appendingPathComponent("terminal.pid").path]
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin", "TERM": "xterm-256color"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try await verify(process, directory)
    }

    private func waitForExit(_ process: Process) async throws {
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !process.isRunning else {
            throw NSError(domain: "CodexSoftLimitTerminalFixtureTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Terminal fixture did not exit"])
        }
    }
}
