import XCTest
@testable import OpenUsage

@MainActor
final class AppRelauncherTests: XCTestCase {
    func testRestartSchedulesBeforeTerminatingAndIgnoresRepeatedClicks() {
        var events: [String] = []
        let relauncher = AppRelauncher(
            scheduleRelaunch: { events.append("schedule") },
            terminate: { events.append("terminate") }
        )

        relauncher.restart()
        relauncher.restart()

        XCTAssertEqual(events, ["schedule", "terminate"])
        XCTAssertTrue(relauncher.isRestarting)
        XCTAssertNil(relauncher.errorMessage)
    }

    func testSchedulingFailureKeepsAppOpenAndAllowsRetry() {
        let diagnostics = DiagnosticEventRecorder()
        var shouldFail = true
        var terminated = false
        let relauncher = AppRelauncher(
            scheduleRelaunch: { if shouldFail { throw CocoaError(.fileNoSuchFile) } },
            terminate: { terminated = true }
        )

        L10n.withLanguage(.korean) { relauncher.restart() }
        XCTAssertFalse(terminated)
        XCTAssertFalse(relauncher.isRestarting)
        XCTAssertEqual(relauncher.errorMessage, "OpenUsage를 다시 시작하지 못했습니다. 앱을 종료한 뒤 다시 열어 언어 변경을 적용하세요.")
        XCTAssertEqual(diagnostics.events.map(\.operation), [.appRestart])
        XCTAssertEqual(diagnostics.events.map(\.result), [.failure])

        shouldFail = false
        relauncher.restart()
        XCTAssertTrue(terminated)
        XCTAssertTrue(relauncher.isRestarting)
        XCTAssertNil(relauncher.errorMessage)
    }

    func testHelperWaitsForOldProcessAndPreservesExactBundlePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppRelauncherTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let opener = directory.appendingPathComponent("fake open")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        let oldApp = Process()
        oldApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldApp.arguments = ["10"]
        try oldApp.run()
        defer { if oldApp.isRunning { oldApp.terminate() } }

        let bundleURL = directory.appendingPathComponent("한글 App ' $(touch injected) `echo value`.app")
        let helper = AppRelauncher.makeRelaunchProcess(
            bundleURL: bundleURL, processIdentifier: oldApp.processIdentifier, openExecutable: opener
        )
        helper.currentDirectoryURL = directory
        let output = Pipe()
        helper.standardOutput = output
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(helper.isRunning, "The helper must wait for the old app to release its instance lock.")
        oldApp.terminate()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while helper.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(helper.isRunning)
        guard !helper.isRunning else { return }
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertEqual(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "-n\n\(bundleURL.path)\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
    }
}
