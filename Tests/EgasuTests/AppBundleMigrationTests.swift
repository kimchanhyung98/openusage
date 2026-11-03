import XCTest
@testable import Egasu

@MainActor
final class AppBundleMigrationTests: XCTestCase {
    func testUpdatedLegacyBundleMovesWithOwnedCommandsBeforeRelaunch() throws {
        let fixture = try makeFixture()
        let legacy = fixture.commands.appendingPathComponent("openusage")
        let current = fixture.commands.appendingPathComponent("egasu")
        try FileManager.default.createSymbolicLink(
            atPath: legacy.path, withDestinationPath: fixture.source.appendingPathComponent("Contents/Helpers/openusage").path
        )
        try FileManager.default.createSymbolicLink(
            atPath: current.path, withDestinationPath: fixture.source.appendingPathComponent("Contents/Helpers/egasu").path
        )
        var relaunched: URL?

        XCTAssertTrue(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { url in
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
            XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("Contents/Helpers/egasu")), Data("helper".utf8))
            for command in [legacy, current] {
                XCTAssertEqual(command.resolvingSymlinksInPath().path,
                               fixture.destination.appendingPathComponent("Contents/Helpers/egasu").path)
            }
            relaunched = url
        })
        XCTAssertEqual(relaunched, fixture.destination)
        let installed = try XCTUnwrap(Bundle(url: fixture.destination))
        XCTAssertEqual(installed.bundleIdentifier, "com.kimchanhyung98.openusage")
        XCTAssertFalse(try AppBundleMigration.migrateIfNeeded(bundle: installed, commandDirectory: fixture.commands) { _ in
            XCTFail("A completed migration must not restart again")
        })
    }

    func testFailedRelaunchSchedulingRestoresAppAndOwnedCommands() throws {
        let fixture = try makeFixture()
        let command = fixture.commands.appendingPathComponent("openusage")
        let originalTarget = fixture.source.appendingPathComponent("Contents/Helpers/openusage").path
        try FileManager.default.createSymbolicLink(atPath: command.path, withDestinationPath: originalTarget)

        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
            throw CocoaError(.executableNotLoadable)
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), originalTarget)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.commands.path), ["openusage"])
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let fixture = try makeFixture()
        try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
        let marker = fixture.destination.appendingPathComponent("keep")
        try Data("other installation".utf8).write(to: marker)

        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
            XCTFail("A destination conflict must keep the current app open")
        })
        XCTAssertEqual(try Data(contentsOf: marker), Data("other installation".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testDanglingDestinationSymlinkIsNeverReplaced() throws {
        let fixture = try makeFixture()
        try FileManager.default.createSymbolicLink(atPath: fixture.destination.path, withDestinationPath: "/missing/other.app")

        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
            XCTFail("A dangling destination is still owned by someone else")
        })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination.path), "/missing/other.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testUnrelatedCommandFileAndSymlinkArePreserved() throws {
        let fixture = try makeFixture()
        let file = fixture.commands.appendingPathComponent("openusage")
        let link = fixture.commands.appendingPathComponent("egasu")
        try Data("user command".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/other/app/helper")

        XCTAssertTrue(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in })
        XCTAssertEqual(try Data(contentsOf: file), Data("user command".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "/other/app/helper")
    }

    func testSourceSymlinkIsNeverMoved() throws {
        let fixture = try makeFixture()
        let actual = fixture.source.deletingLastPathComponent().appendingPathComponent("Actual.app")
        try FileManager.default.moveItem(at: fixture.source, to: actual)
        try FileManager.default.createSymbolicLink(at: fixture.source, withDestinationURL: actual)

        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
            XCTFail("A symlink must not be treated as an installed app directory")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: actual.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.source.path), actual.path)
    }

    func testPermissionFailureKeepsTheOriginalApp() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(
            bundle: fixture.bundle, commandDirectory: fixture.commands, fileManager: DeniedMoveFileManager()
        ) { _ in XCTFail("A failed move must not terminate the old process") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
    }

    func testReadOnlyCommandDirectoryUsesAuthorizationBeforeRelaunch() throws {
        let fixture = try makeReadOnlyCommands()
        var approvals = 0
        var relaunched = false
        XCTAssertTrue(try AppBundleMigration.migrateIfNeeded(
            bundle: fixture.bundle, commandDirectory: fixture.commands,
            replacePrivilegedLink: { url, expected, target in
                approvals += 1
                try self.replaceAsAuthorized(url, expected: expected, target: target)
            }
        ) { _ in relaunched = true })
        XCTAssertEqual(approvals, 1)
        XCTAssertTrue(relaunched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertEqual(fixture.commands.appendingPathComponent("openusage").resolvingSymlinksInPath().path,
                       fixture.destination.appendingPathComponent("Contents/Helpers/egasu").path)
    }

    func testCancelledOrFailedAuthorizationPreservesOriginalAppAndCommand() throws {
        for error in [CocoaError(.userCancelled), CocoaError(.fileWriteNoPermission)] {
            let fixture = try makeReadOnlyCommands()
            let originalTarget = fixture.source.appendingPathComponent("Contents/Helpers/openusage").path
            var approvals = 0
            XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(
                bundle: fixture.bundle, commandDirectory: fixture.commands,
                replacePrivilegedLink: { _, _, _ in approvals += 1; throw error }
            ) { _ in XCTFail("Authorization failure must not schedule a restart") }) {
                XCTAssertEqual(($0 as NSError).code, error.errorCode)
            }
            XCTAssertEqual(approvals, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
                atPath: fixture.commands.appendingPathComponent("openusage").path
            ), originalTarget)
        }
    }

    func testFailedRelaunchRestoresAnAuthorizedCommandReplacement() throws {
        let fixture = try makeReadOnlyCommands()
        let originalTarget = fixture.source.appendingPathComponent("Contents/Helpers/openusage").path
        var approvals = 0
        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(
            bundle: fixture.bundle, commandDirectory: fixture.commands,
            replacePrivilegedLink: { url, expected, target in
                approvals += 1
                try self.replaceAsAuthorized(url, expected: expected, target: target)
            }
        ) { _ in throw CocoaError(.executableNotLoadable) })
        XCTAssertEqual(approvals, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(
            atPath: fixture.commands.appendingPathComponent("openusage").path
        ), originalTarget)
    }

    private func makeReadOnlyCommands() throws -> Fixture {
        let fixture = try makeFixture()
        try FileManager.default.createSymbolicLink(
            atPath: fixture.commands.appendingPathComponent("openusage").path,
            withDestinationPath: fixture.source.appendingPathComponent("Contents/Helpers/openusage").path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.commands.path)
        addTeardownBlock {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.commands.path)
        }
        return fixture
    }

    /// 관리자 승인은 대역으로 처리하되 링크 교체 스크립트는 실제 파일시스템에서 실행.
    private func replaceAsAuthorized(_ url: URL, expected: String, target: String) throws {
        let directory = url.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CommandLineToolInstaller.replacementCommand(at: url, expected: expected, target: target)]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testRollbackDoesNotOverwriteACommandChangedByAnotherProcess() throws {
        let fixture = try makeFixture()
        let command = fixture.commands.appendingPathComponent("openusage")
        try FileManager.default.createSymbolicLink(
            atPath: command.path, withDestinationPath: fixture.source.appendingPathComponent("Contents/Helpers/openusage").path
        )

        XCTAssertThrowsError(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
            try FileManager.default.removeItem(at: command)
            try FileManager.default.createSymbolicLink(atPath: command.path, withDestinationPath: "/unrelated/helper")
            throw CocoaError(.executableNotLoadable)
        })
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), "/unrelated/helper")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testDevelopmentUpstreamAndUnchangedOldBuildsAreNotMigrated() throws {
        for (identifier, name, feed) in [
            ("com.kimchanhyung98.openusage.dev", "egasu", true),
            ("com.robinebers.openusage", "egasu", true),
            ("com.kimchanhyung98.openusage", "OpenUsage", true),
            ("com.kimchanhyung98.openusage", "egasu", false)
        ] {
            let fixture = try makeFixture(identifier: identifier, name: name, feed: feed)
            XCTAssertFalse(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
                XCTFail("Only a newly installed production egasu build may rename the legacy path")
            })
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        }
    }

    func testCustomAppFilenameIsPreserved() throws {
        let fixture = try makeFixture(filename: "My Usage.app")
        XCTAssertFalse(try AppBundleMigration.migrateIfNeeded(bundle: fixture.bundle, commandDirectory: fixture.commands) { _ in
            XCTFail("A user-chosen filename must be preserved")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    private struct Fixture {
        let bundle: Bundle
        let source: URL
        let destination: URL
        let commands: URL
    }

    private final class DeniedMoveFileManager: FileManager, @unchecked Sendable {
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func makeFixture(
        filename: String = "OpenUsage.app",
        identifier: String = "com.kimchanhyung98.openusage",
        name: String = "egasu",
        feed: Bool = true
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppBundleMigrationTests.\(UUID().uuidString)")
        let source = root.appendingPathComponent(filename)
        let helpers = source.appendingPathComponent("Contents/Helpers")
        let commands = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var info = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL"]
        if feed { info["SUFeedURL"] = "https://example.invalid/appcast.xml" }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Contents/Info.plist"))
        try Data("helper".utf8).write(to: helpers.appendingPathComponent("egasu"))
        try FileManager.default.createSymbolicLink(atPath: helpers.appendingPathComponent("openusage").path, withDestinationPath: "egasu")
        return Fixture(bundle: try XCTUnwrap(Bundle(url: source)), source: source,
                       destination: root.appendingPathComponent("egasu.app"), commands: commands)
    }
}
