import XCTest
@testable import EgasuCLI

final class AppBundleLocatorTests: XCTestCase {
    func testFindsContainingAppThroughHelperSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("egasu.app")
        let contents = app.appendingPathComponent("Contents")
        let helpers = contents.appendingPathComponent("Helpers")
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.kimchanhyung98.openusage",
            "CFBundleShortVersionString": "1.2.3"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))
        let helper = helpers.appendingPathComponent("egasu")
        try Data().write(to: helper)
        let symlink = bin.appendingPathComponent("egasu")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: helper)
        defer { try? FileManager.default.removeItem(at: root) }

        let located = AppBundleLocator.locate(
            executableURL: symlink,
            environment: [:]
        )

        XCTAssertEqual(located.bundleIdentifier, "com.kimchanhyung98.openusage")
        XCTAssertEqual(located.version, "1.2.3")

        let legacyHelper = helpers.appendingPathComponent("openusage")
        try FileManager.default.createSymbolicLink(atPath: legacyHelper.path, withDestinationPath: "egasu")
        let legacyCommand = bin.appendingPathComponent("openusage")
        try FileManager.default.createSymbolicLink(at: legacyCommand, withDestinationURL: legacyHelper)

        let legacy = AppBundleLocator.locate(executableURL: legacyCommand, environment: [:])
        XCTAssertEqual(legacy.bundleIdentifier, located.bundleIdentifier)
        XCTAssertEqual(legacy.version, located.version)
    }

    func testEnvironmentCanSelectDefaultsSuiteForDevelopment() {
        let located = AppBundleLocator.locate(
            executableURL: URL(fileURLWithPath: "/tmp/egasu"),
            environment: ["EGASU_DEFAULTS_SUITE": "com.example.dev"]
        )

        XCTAssertEqual(located.bundleIdentifier, "com.example.dev")
    }

    func testLegacyEnvironmentStillSelectsDefaultsSuite() {
        let located = AppBundleLocator.locate(
            executableURL: URL(fileURLWithPath: "/tmp/egasu"),
            environment: ["OPENUSAGE_DEFAULTS_SUITE": "com.example.legacy"]
        )

        XCTAssertEqual(located.bundleIdentifier, "com.example.legacy")
    }

    func testNewEnvironmentTakesPrecedenceOverLegacyEnvironment() {
        let located = AppBundleLocator.locate(
            executableURL: URL(fileURLWithPath: "/tmp/egasu"),
            environment: ["EGASU_DEFAULTS_SUITE": "com.example.new", "OPENUSAGE_DEFAULTS_SUITE": "com.example.legacy"]
        )

        XCTAssertEqual(located.bundleIdentifier, "com.example.new")
    }
}
