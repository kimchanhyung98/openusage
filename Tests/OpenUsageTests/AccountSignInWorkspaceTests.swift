import XCTest
@testable import OpenUsage

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

    func testPrepareRefusesASymlinkedFamilyComponent() throws {
        let base = try makeBase()
        let outside = try makeOutside()
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("claude"),
            withDestinationURL: outside
        )
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent(let path) = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
            XCTAssertEqual(path, base.appendingPathComponent("claude").path)
            XCTAssertFalse(error.localizedDescription.contains(outside.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("profile-1").path))
    }

    func testPrepareRefusesASymlinkedBaseDirectory() throws {
        let outside = try makeOutside()
        let base = try makeSymlinkedBase(to: outside)
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent(let path) = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
            XCTAssertEqual(path, base.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("claude/profile-1").path))
    }

    func testPrepareRefusesASymlinkedDefaultOpenUsageDirectory() throws {
        let applicationSupport = try makeApplicationSupport()
        let outside = try makeOutside()
        let openUsage = applicationSupport.appendingPathComponent("OpenUsage")
        try FileManager.default.createSymbolicLink(at: openUsage, withDestinationURL: outside)
        let fileManager = ApplicationSupportFileManager(applicationSupport: applicationSupport)
        let workspace = AccountSignInWorkspace(fileManager: fileManager)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent(let path) = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
            XCTAssertEqual(path, openUsage.path)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: outside.appendingPathComponent("AccountSignIn/claude/profile-1").path)
        )
    }

    func testPrepareRefusesASymlinkedDefaultAccountSignInDirectory() throws {
        let applicationSupport = try makeApplicationSupport()
        let outside = try makeOutside()
        let openUsage = applicationSupport.appendingPathComponent("OpenUsage")
        try FileManager.default.createDirectory(at: openUsage, withIntermediateDirectories: true)
        let accountSignIn = openUsage.appendingPathComponent("AccountSignIn")
        try FileManager.default.createSymbolicLink(at: accountSignIn, withDestinationURL: outside)
        let fileManager = ApplicationSupportFileManager(applicationSupport: applicationSupport)
        let workspace = AccountSignInWorkspace(fileManager: fileManager)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent(let path) = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
            XCTAssertEqual(path, accountSignIn.path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("claude/profile-1").path))
    }

    func testPrepareRefusesASymlinkedProfileComponent() throws {
        let base = try makeBase()
        let family = base.appendingPathComponent("claude")
        let outside = try makeOutside()
        try FileManager.default.createDirectory(at: family, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outside.path)
        try FileManager.default.createSymbolicLink(
            at: family.appendingPathComponent("profile-1"),
            withDestinationURL: outside
        )
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }
        XCTAssertEqual(posixPermissions(outside.path), 0o755)
    }

    func testPrepareChecksContainmentBeforeChangingPermissions() throws {
        let base = try makeBase()
        let family = base.appendingPathComponent("claude")
        let outside = try makeOutside()
        let outsideProfile = outside.appendingPathComponent("profile-1")
        try FileManager.default.createDirectory(at: outsideProfile, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outsideProfile.path)
        let fileManager = FamilySymlinkSwapFileManager(family: family, destination: outside)
        let workspace = AccountSignInWorkspace(baseDirectory: base, fileManager: fileManager)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.outsideOwnedRoot(let path) = error else {
                return XCTFail("expected outsideOwnedRoot, got \(error)")
            }
            XCTAssertEqual(path, outsideProfile.path)
        }
        XCTAssertEqual(posixPermissions(outsideProfile.path), 0o755)
    }

    func testRemoveRefusesASymlinkedFamilyComponent() throws {
        let base = try makeBase()
        let outside = try makeOutside()
        let sentinel = outside.appendingPathComponent("profile-1/keep.txt")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("claude"),
            withDestinationURL: outside
        )
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.remove(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemoveRefusesASymlinkedBaseDirectory() throws {
        let outside = try makeOutside()
        let sentinel = outside.appendingPathComponent("claude/profile-1/keep.txt")
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: sentinel)
        let base = try makeSymlinkedBase(to: outside)
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.remove(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent(let path) = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
            XCTAssertEqual(path, base.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemoveRefusesASymlinkedProfileComponent() throws {
        let base = try makeBase()
        let family = base.appendingPathComponent("claude")
        let outside = try makeOutside()
        let sentinel = outside.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: family, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sentinel)
        let profile = family.appendingPathComponent("profile-1")
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: outside)
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertThrowsError(try workspace.remove(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: profile.path)[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testRemoveRefusesADanglingProfileSymlink() throws {
        let base = try makeBase()
        let family = base.appendingPathComponent("claude")
        let profile = family.appendingPathComponent("profile-1")
        let missingTarget = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.missing.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: family, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: profile, withDestinationURL: missingTarget)
        let workspace = AccountSignInWorkspace(baseDirectory: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
        XCTAssertThrowsError(try workspace.remove(family: "claude", profileID: "profile-1")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: profile.path)[.type] as? FileAttributeType,
            .typeSymbolicLink
        )
    }

    func testPreparePropagatesComponentMetadataErrors() throws {
        let base = try makeBase()
        let family = base.appendingPathComponent("claude")
        let fileManager = AttributeFailureFileManager(failingPath: family.path)
        let workspace = AccountSignInWorkspace(baseDirectory: base, fileManager: fileManager)

        XCTAssertThrowsError(try workspace.prepare(family: "claude", profileID: "profile-1")) { error in
            guard let cocoaError = error as? CocoaError else {
                return XCTFail("expected CocoaError, got \(error)")
            }
            XCTAssertEqual(cocoaError.code, .fileReadNoPermission)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: family.path))
    }

    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.\(UUID().uuidString)/AccountSignIn")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base.deletingLastPathComponent()) }
        return base
    }

    private func makeOutside() throws -> URL {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.outside.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        return outside
    }

    private func makeApplicationSupport() throws -> URL {
        let applicationSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.application-support.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: applicationSupport) }
        return applicationSupport
    }

    private func makeSymlinkedBase(to destination: URL) throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountSignInWorkspace.root.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = parent.appendingPathComponent("AccountSignIn")
        try FileManager.default.createSymbolicLink(at: base, withDestinationURL: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return base
    }

    private func posixPermissions(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
}

private final class AttributeFailureFileManager: FileManager, @unchecked Sendable {
    private let failingPath: String

    init(failingPath: String) {
        self.failingPath = failingPath
        super.init()
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        guard path != failingPath else {
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.attributesOfItem(atPath: path)
    }
}

private final class ApplicationSupportFileManager: FileManager, @unchecked Sendable {
    private let applicationSupport: URL

    init(applicationSupport: URL) {
        self.applicationSupport = applicationSupport
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        guard directory == .applicationSupportDirectory, domainMask == .userDomainMask else {
            return super.urls(for: directory, in: domainMask)
        }
        return [applicationSupport]
    }
}

private final class FamilySymlinkSwapFileManager: FileManager, @unchecked Sendable {
    private let family: URL
    private let destination: URL
    private var didSwap = false

    init(family: URL, destination: URL) {
        self.family = family
        self.destination = destination
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
        guard !didSwap, url.deletingLastPathComponent().path == family.path else { return }
        didSwap = true
        try super.removeItem(at: family)
        try super.createSymbolicLink(at: family, withDestinationURL: destination)
    }
}
