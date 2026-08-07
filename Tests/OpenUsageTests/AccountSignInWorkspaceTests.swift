import XCTest
@testable import OpenUsage

/// The app-owned sign-in workspace: profile-id-derived layout, user-private permissions, and no
/// way out of the owned root.
final class AccountSignInWorkspaceTests: XCTestCase {
    func testDirectoryLayoutDerivesFromFamilyAndProfileID() throws {
        let base = try makeBase()
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        let directory = try workspace.directory(family: "claude", profileID: "profile-1")

        XCTAssertEqual(directory.path, base.appendingPathComponent("claude/profile-1").path)
    }

    func testPrepareCreatesPrivateDirectoriesAndPrivateFiles() throws {
        let base = try makeBase()
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        let directory = try workspace.prepare(family: "codex", profileID: "profile-2")
        try workspace.writePrivateFile("secret", to: directory.appendingPathComponent("auth.json"))

        XCTAssertEqual(posixPermissions(directory.path), 0o700)
        XCTAssertEqual(posixPermissions(directory.appendingPathComponent("auth.json").path), 0o600)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("auth.json"), encoding: .utf8),
            "secret"
        )
    }

    func testInvalidComponentsAreRejected() throws {
        let workspace = AccountSignInWorkspace(baseDirectory: try makeBase())

        for component in ["", "a/b", "a\\b", ".", ".."] {
            XCTAssertThrowsError(try workspace.directory(family: "claude", profileID: component)) { error in
                guard case AccountSignInWorkspace.WorkspaceError.invalidComponent = error else {
                    return XCTFail("expected invalidComponent for \(component), got \(error)")
                }
            }
            XCTAssertThrowsError(try workspace.directory(family: component, profileID: "p"))
        }
    }

    func testRemoveDeletesOnlyTheOneProfileWorkspace() throws {
        let base = try makeBase()
        let workspace = AccountSignInWorkspace(baseDirectory: base)
        let first = try workspace.prepare(family: "claude", profileID: "profile-1")
        let sibling = try workspace.prepare(family: "claude", profileID: "profile-2")
        let otherFamily = try workspace.prepare(family: "codex", profileID: "profile-3")

        try workspace.remove(family: "claude", profileID: "profile-1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherFamily.path))
    }

    func testRemoveOfAMissingWorkspaceIsANoOp() throws {
        let workspace = AccountSignInWorkspace(baseDirectory: try makeBase())

        XCTAssertNoThrow(try workspace.remove(family: "claude", profileID: "never-created"))
    }

    func testPrepareRefusesASymlinkEscapingTheOwnedRoot() throws {
        let base = try makeBase()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.outside.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        // `<base>/claude` points outside the owned root — prepare must refuse to hand it out.
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("claude"),
            withDestinationURL: outside
        )
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.outsideOwnedRoot = error else {
                return XCTFail("expected outsideOwnedRoot, got \(error)")
            }
        }
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.\(UUID().uuidString)/AccountSignIn")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        return base
    }

    private func posixPermissions(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
}
