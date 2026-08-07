import Foundation

/// The app-owned home used to complete an official provider sign-in without touching the Shared
/// Runtime Home: `~/Library/Application Support/OpenUsage/AccountSignIn/<family>/<profile-id>/`.
/// The path derives from the immutable profile id and is never shown as an editable field. It only
/// hosts official logins, re-logins, and identity verification — never a normal CLI session.
struct AccountSignInWorkspace {
    enum WorkspaceError: LocalizedError {
        case invalidComponent(String)
        case outsideOwnedRoot(String)

        var errorDescription: String? {
            switch self {
            case .invalidComponent(let component):
                "Invalid sign-in workspace component: \(component)"
            case .outsideOwnedRoot(let path):
                "The sign-in workspace resolved outside OpenUsage's owned directory: \(path)"
            }
        }
    }

    let baseDirectory: URL
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectory {
            self.baseDirectory = baseDirectory.standardizedFileURL
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            self.baseDirectory = applicationSupport
                .appendingPathComponent("OpenUsage/AccountSignIn", isDirectory: true)
                .standardizedFileURL
        }
    }

    func directory(family: String, profileID: String) throws -> URL {
        try validate(family)
        try validate(profileID)
        return baseDirectory
            .appendingPathComponent(family, isDirectory: true)
            .appendingPathComponent(profileID, isDirectory: true)
    }

    /// Creates the workspace private to the user (`0700` at every level) and refuses to hand out a
    /// path whose symlinks escape the app-owned root.
    @discardableResult
    func prepare(family: String, profileID: String) throws -> URL {
        let directory = try directory(family: family, profileID: profileID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let resolvedRoot = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDirectory == resolvedRoot || resolvedDirectory.hasPrefix(resolvedRoot + "/") else {
            throw WorkspaceError.outsideOwnedRoot(resolvedDirectory)
        }
        return directory
    }

    /// Deletes only this profile's workspace. Shared Runtime Homes and any historical
    /// `~/.claude-*`/`~/.codex-*` directories are never in scope here.
    func remove(family: String, profileID: String) throws {
        let directory = try directory(family: family, profileID: profileID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// Writes one credential file inside a workspace: parent `0700`, file `0600`, atomic replace.
    func writePrivateFile(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(text.utf8).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func validate(_ component: String) throws {
        guard !component.isEmpty,
              !component.contains("/"),
              !component.contains("\\"),
              component != ".",
              component != "..",
              !component.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw WorkspaceError.invalidComponent(component)
        }
    }
}
