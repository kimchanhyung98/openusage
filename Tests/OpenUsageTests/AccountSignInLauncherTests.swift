import XCTest
@testable import OpenUsage

final class AccountSignInLauncherTests: XCTestCase {
    func testCancelledLoginDoesNotLaunchTheCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let command = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\n: > \"$CODEX_HOME/launched\"\n".utf8).write(to: command)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AccountSignInLauncher().runLogin(
                family: "codex", home: root.path,
                baseEnvironment: ["PATH": root.path], usesLoginShellPATH: false
            )
        }

        do {
            _ = try await task.value
            XCTFail("Cancelled login must not succeed")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("launched").path))
    }

    func testLoginArgumentsMatchTheInstalledCLIs() {
        XCTAssertEqual(AccountSignInLauncher.loginArguments(family: "claude"), ["auth", "login"])
        XCTAssertEqual(
            AccountSignInLauncher.loginArguments(family: "codex"),
            ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        )
        XCTAssertEqual(AccountSignInLauncher.loginArguments(family: "cursor"), [])
    }

    func testClaudeLoginEnvironmentRemovesAuthOverridesAndPinsTheHome() {
        var base = ["PATH": "/usr/bin", "EDITOR": "vim"]
        for variable in AccountSignInLauncher.claudeAuthEnvironmentRemovals {
            base[variable] = "leaked"
        }

        let environment = AccountSignInLauncher.loginEnvironment(
            family: "claude",
            home: "/tmp/workspace",
            base: base
        )

        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/workspace")
        for variable in AccountSignInLauncher.claudeAuthEnvironmentRemovals {
            XCTAssertNil(environment[variable], "\(variable) must be removed from the login child")
        }
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["EDITOR"], "vim")
    }

    func testCodexLoginEnvironmentRemovesAuthOverridesAndPinsTheHome() {
        var base = ["PATH": "/usr/bin"]
        for variable in AccountSignInLauncher.codexAuthEnvironmentRemovals {
            base[variable] = "leaked"
        }

        let environment = AccountSignInLauncher.loginEnvironment(
            family: "codex",
            home: "/tmp/workspace",
            base: base
        )

        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/workspace")
        for variable in AccountSignInLauncher.codexAuthEnvironmentRemovals {
            XCTAssertNil(environment[variable], "\(variable) must be removed from the login child")
        }
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }
}
