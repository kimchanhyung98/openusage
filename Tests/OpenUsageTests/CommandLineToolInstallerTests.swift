import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CommandLineToolInstallerTests: XCTestCase {
    private func fixture() throws -> (root: URL, source: String, destination: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("OpenUsage.app/Contents/Helpers/openusage")
        let destination = root.appendingPathComponent("bin/openusage")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        return (root, source.path, destination.path)
    }

    func testInstallAndUninstallOwnSymlink() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { operation, source, destination in
                do {
                    switch operation {
                    case .install:
                        try FileManager.default.createDirectory(
                            atPath: (destination as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
                    case .uninstall:
                        try FileManager.default.removeItem(atPath: destination)
                    }
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
        )

        XCTAssertEqual(installer.status, .notInstalled)
        installer.install()
        XCTAssertEqual(installer.status, .installed)
        installer.uninstall()
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testPrivilegedCommandStatusesAreNotAuthorizationFailures() throws {
        let cases: [(Int?, CommandLineToolInstaller.Operation, ErrorCategory)] = [
            (1, .install, .subprocess),
            (1, .uninstall, .subprocess),
            (255, .install, .subprocess),
            (73, .install, .subprocess),
            (74, .uninstall, .subprocess),
            (75, .uninstall, .subprocess),
            (-60005, .install, .permission),
            (nil, .install, .other),
            (-999, .uninstall, .other),
            (0, .install, .other),
            (256, .install, .other)
        ]
        for (code, operation, category) in cases {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let previousSink = AppLog.sink
            AppLog.sink = LogFile(directory: fixture.root, fileName: "diagnostics.log")
            AppLog.sink.open()
            AppLog.reloadLevel(.info)
            defer {
                AppLog.sink = previousSink
                AppLog.reloadLevel()
            }
            let diagnostics = DiagnosticEventRecorder()
            if case .uninstall = operation {
                try FileManager.default.createDirectory(
                    atPath: (fixture.destination as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(atPath: fixture.destination, withDestinationPath: fixture.source)
            }
            let installer = CommandLineToolInstaller(
                sourcePath: fixture.source,
                destinationPath: fixture.destination,
                performPrivileged: { _, _, _ in .failure("PRIVATE_COMMAND_FAILURE", code: code) }
            )
            let expectedOperation: DiagnosticOperation
            switch operation {
            case .install:
                installer.install()
                expectedOperation = .cliInstall
                XCTAssertEqual(installer.status, .notInstalled)
            case .uninstall:
                installer.uninstall()
                expectedOperation = .cliRemove
                XCTAssertEqual(installer.status, .installed)
            }

            let lines = try String(contentsOf: fixture.root.appendingPathComponent("diagnostics.log"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 1, "status=\(String(describing: code))")
            let line = try XCTUnwrap(lines.first)
            XCTAssertTrue(line.contains("[ERROR]"), line)
            if let code {
                XCTAssertTrue(line.contains("; error_code=\(code)"), line)
            } else {
                XCTAssertFalse(line.contains("error_code="), line)
            }
            XCTAssertFalse(line.contains("authorization_error_code"), line)
            XCTAssertFalse(line.contains("PRIVATE_COMMAND_FAILURE"), line)
            XCTAssertEqual(diagnostics.events, [DiagnosticEvent(expectedOperation, result: .failure, category: category)])
            XCTAssertTrue(installer.errorMessage?.contains("PRIVATE_COMMAND_FAILURE") == true)
        }
    }

    func testCancelledAuthorizationDoesNotBecomeFailure() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let diagnostics = DiagnosticEventRecorder()
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in .cancelled }
        )

        installer.install()

        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.cliInstall, result: .cancelled)])
        XCTAssertNil(installer.errorMessage)
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testForeignPathIsNeverOverwritten() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: URL(fileURLWithPath: fixture.destination))
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.install()
        XCTAssertFalse(operationRan)
        XCTAssertNotNil(installer.errorMessage)
        XCTAssertEqual(try String(contentsOfFile: fixture.destination, encoding: .utf8), "foreign")
    }

    func testForeignSymlinkIsNeverClaimedOrRemoved() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.destination,
            withDestinationPath: "/tmp/another-openusage"
        )
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.uninstall()
        XCTAssertFalse(operationRan)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination),
            "/tmp/another-openusage"
        )
    }
}
