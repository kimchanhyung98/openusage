import Foundation

/// Shared Runtime Home을 건드리지 않고 공식 provider sign-in을 완료하는 앱 소유 home — `~/Library/Application Support/OpenUsage/AccountSignIn/<family>/<profile-id>/`.
/// 경로는 불변 profile id에서 파생, 편집 가능 필드로 노출 금지. 공식 로그인·re-login·identity 검증 전용 — 일반 CLI 세션 금지.
/// 내부 `FileManager` delegate 미사용 — credential read task로 안전하게 전달 가능.
struct AccountSignInWorkspace: @unchecked Sendable {
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

    /// 사용자 전용 workspace 생성(전 단계 `0700`) — symlink가 앱 소유 root를 탈출하는 경로는 거부.
    @discardableResult
    func prepare(family: String, profileID: String) throws -> URL {
        let directory = try directory(family: family, profileID: profileID)
        try assertNoSymlinkComponents(family: family, profileID: profileID)
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

    private func assertNoSymlinkComponents(family: String, profileID: String) throws {
        var current = baseDirectory
        for component in [family, profileID] {
            current.appendPathComponent(component)
            do {
                let attributes = try fileManager.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw WorkspaceError.outsideOwnedRoot(current.path)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                throw error
            }
        }
    }

    /// 이 profile의 workspace만 삭제 — Shared Runtime Home·역사적 `~/.claude-*`/`~/.codex-*` 디렉터리는 범위 밖.
    func remove(family: String, profileID: String) throws {
        let directory = try directory(family: family, profileID: profileID)
        try assertNoSymlinkComponents(family: family, profileID: profileID)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    /// workspace 내 credential 파일 1개 기록 — parent `0700`, 파일 `0600`, 원자적 교체.
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
