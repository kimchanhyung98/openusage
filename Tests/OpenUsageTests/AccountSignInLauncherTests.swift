import XCTest
@testable import OpenUsage

/// The official-login launcher: scoped home pinned, auth overrides stripped, Codex forced onto the
/// file credential store.
final class AccountSignInLauncherTests: XCTestCase {
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
