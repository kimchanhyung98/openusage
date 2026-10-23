import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerNativeTests: XCTestCase {
    func testInstalledCLIValidatesIsolationBeforeAnyMessageLaunch() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENUSAGE_RUN_CODEX_TIMER_TEST"] == "1" else {
            throw XCTSkip("Opt-in native weekly timer fixture requires an explicit Codex CLI executable")
        }
        let executable = URL(fileURLWithPath: try XCTUnwrap(environment["OPENUSAGE_CODEX_TEST_EXECUTABLE"]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenUsage.TimerNative.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = CodexWeeklyTimerExecutor(executableResolver: { executable }, baseDirectory: directory)
        let auth = CodexAuth(tokens: CodexTokens(
            accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            idToken: "synthetic-id", accountID: "synthetic-account"
        ))
        var reachedLaunchCheck = false
        let result = await executor.execute(auth: auth, canLaunch: {
            reachedLaunchCheck = true
            return false
        })

        XCTAssertFalse(result.launched)
        XCTAssertFalse(result.completed)
        XCTAssertNil(result.updatedAuth)
        if environment["OPENUSAGE_CODEX_TIMER_EXPECT_UNSUPPORTED"] == "1" {
            XCTAssertFalse(reachedLaunchCheck)
            XCTAssertEqual(result.failureDescription,
                           "This Codex CLI could not prepare an isolated weekly timer message. Update Codex and try again.")
        } else {
            XCTAssertTrue(reachedLaunchCheck)
            XCTAssertEqual(result.failureDescription, "Codex weekly timer account changed before the message started.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        print("Native Codex weekly timer: preflightSupported=\(reachedLaunchCheck), messageLaunched=\(result.launched), workspaceRemoved=true")
    }
}
