import XCTest
@testable import OpenUsageCLI

final class AccountCommandTests: XCTestCase {
    func testListParsing() throws {
        XCTAssertEqual(try AccountCommand.parse(["list"]), .list(family: nil, json: false))
        XCTAssertEqual(try AccountCommand.parse(["list", "codex"]), .list(family: "codex", json: false))
        XCTAssertEqual(try AccountCommand.parse(["list", "--json"]), .list(family: nil, json: true))
        XCTAssertEqual(try AccountCommand.parse(["list", "Claude", "--json"]), .list(family: "claude", json: true))
        XCTAssertThrowsError(try AccountCommand.parse(["list", "grok"]))
        XCTAssertThrowsError(try AccountCommand.parse(["list", "claude", "codex"]))
        XCTAssertThrowsError(try AccountCommand.parse(["list", "--home"]))
    }

    func testCurrentParsing() throws {
        XCTAssertEqual(try AccountCommand.parse(["current"]), .current(family: nil))
        XCTAssertEqual(try AccountCommand.parse(["current", "codex"]), .current(family: "codex"))
        XCTAssertThrowsError(try AccountCommand.parse(["current", "claude", "codex"]))
    }

    func testMissingAndUnknownVerbs() {
        XCTAssertThrowsError(try AccountCommand.parse([]))
        XCTAssertThrowsError(try AccountCommand.parse(["switch", "codex", "work"]))
        XCTAssertThrowsError(try AccountCommand.parse(["run", "codex", "work"]))
    }

    func testAccountNamespaceIsReservedInCLIArguments() throws {
        let parsed = try CLIArguments.parse(["account", "list", "codex"])
        XCTAssertEqual(parsed.account, .list(family: "codex", json: false))
        XCTAssertNil(parsed.providerID)

        // The provider grammar is untouched.
        let provider = try CLIArguments.parse(["codex", "--force"])
        XCTAssertEqual(provider.providerID, "codex")
        XCTAssertNil(provider.account)
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }
}
