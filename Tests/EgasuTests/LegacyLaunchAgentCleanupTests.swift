import XCTest
@testable import Egasu

final class LegacyLaunchAgentCleanupTests: XCTestCase {
    // MARK: - Removal decision (pure)

    /// #874 실사례 — Tauri 시절 agent의 lowercase binary 이름이 case-insensitive APFS에서 현 bundle로 resolve
    func testTauriLowercaseProgramInsideBundleIsRemoved() {
        XCTAssertTrue(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/egasu.app/Contents/MacOS/egasu",
            bundlePath: "/Applications/egasu.app"
        ))
    }

    func testExactCaseProgramInsideBundleIsRemoved() {
        XCTAssertTrue(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/egasu.app/Contents/MacOS/egasu",
            bundlePath: "/Applications/egasu.app"
        ))
    }

    func testProgramOutsideBundleIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/usr/local/bin/egasu",
            bundlePath: "/Applications/egasu.app"
        ))
    }

    func testMissingProgramIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: nil,
            bundlePath: "/Applications/egasu.app"
        ))
    }

    /// unbundled `swift run`의 build dir bundle path는 매칭 금지 — dev run이 실제 agent를 삭제하지 않도록
    func testNonAppBundlePathNeverMatches() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Users/dev/egasu/.build/debug/egasu",
            bundlePath: "/Users/dev/egasu/.build/debug"
        ))
    }

    /// prefix 매칭은 component 단위 — `egasu.app2` 같은 sibling은 다른 bundle
    func testSiblingDirectorySharingPrefixIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/egasu.app2/Contents/MacOS/egasu",
            bundlePath: "/Applications/egasu.app"
        ))
    }

    func testProgramEqualToBundlePathIsKept() {
        XCTAssertFalse(LegacyLaunchAgentCleanup.shouldRemove(
            programPath: "/Applications/egasu.app",
            bundlePath: "/Applications/egasu.app"
        ))
    }

    // MARK: - Plist parsing

    func testParseReadsFirstProgramArgument() throws {
        // tauri-plugin-autostart가 쓰던 shape 그대로 (#874)
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist([
            "Label": "egasu",
            "ProgramArguments": ["/Applications/egasu.app/Contents/MacOS/egasu"],
            "RunAtLoad": true
        ]))
        XCTAssertEqual(agent.programPath, "/Applications/egasu.app/Contents/MacOS/egasu")
    }

    func testParsePrefersProgramKeyOverProgramArguments() throws {
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist([
            "Program": "/Applications/egasu.app/Contents/MacOS/egasu",
            "ProgramArguments": ["/somewhere/else"]
        ]))
        XCTAssertEqual(agent.programPath, "/Applications/egasu.app/Contents/MacOS/egasu")
    }

    func testParseWithoutProgramKeysYieldsNil() throws {
        let agent = try LegacyLaunchAgentCleanup.parse(plistData: plist(["Label": "egasu"]))
        XCTAssertNil(agent.programPath)
    }

    func testParseRejectsNonPlistData() {
        XCTAssertThrowsError(try LegacyLaunchAgentCleanup.parse(plistData: Data("not a plist".utf8)))
    }

    // MARK: - End to end (temp filesystem)

    func testLeftoverTauriAgentFileIsDeleted() throws {
        let agentURL = try writeAgent([
            "Label": "egasu",
            "ProgramArguments": ["/Applications/egasu.app/Contents/MacOS/egasu"],
            "RunAtLoad": true
        ])
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/egasu.app"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testForeignAgentFileIsKept() throws {
        let agentURL = try writeAgent([
            "Label": "egasu",
            "ProgramArguments": ["/usr/local/bin/something-else"]
        ])
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/egasu.app"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testUnreadableAgentFileIsKept() throws {
        let agentURL = try writeRaw(Data("not a plist".utf8))
        defer { try? FileManager.default.removeItem(at: agentURL.deletingLastPathComponent()) }

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/egasu.app"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: agentURL.path))
    }

    func testMissingAgentFileIsANoOp() {
        let agentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("egasu-agent-\(UUID().uuidString)")
            .appendingPathComponent("OpenUsage.plist")

        LegacyLaunchAgentCleanup.removeLeftoverAgent(
            agentURL: agentURL, bundlePath: "/Applications/egasu.app"
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
    }

    // MARK: - Helpers

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func writeAgent(_ dict: [String: Any]) throws -> URL {
        try writeRaw(plist(dict))
    }

    private func writeRaw(_ data: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("egasu-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("OpenUsage.plist")
        try data.write(to: url)
        return url
    }
}
