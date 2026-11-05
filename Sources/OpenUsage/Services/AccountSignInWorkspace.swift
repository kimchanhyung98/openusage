import Foundation

/// Shared Runtime Home을 건드리지 않고 공식 provider sign-in을 완료하는 앱 소유 home — `~/Library/Application Support/OpenUsage/AccountSignIn/<family>/<profile-id>/`.
/// 계정 경로 아래 로그인 시도별 작업 공간 배치, 편집 가능 필드로 노출 금지. 공식 로그인·re-login·identity 검증 전용 — 일반 CLI 세션 금지.
/// 내부 `FileManager` delegate 미사용 — credential read task로 안전하게 전달 가능.
struct AccountSignInWorkspace: @unchecked Sendable {
    enum WorkspaceError: LocalizedError {
        case invalidComponent(String)
        case outsideOwnedRoot(String)
        case symlinkedComponent(String)

        var errorDescription: String? {
            switch self {
            case .invalidComponent(let component):
                "Invalid sign-in workspace component: \(component)"
            case .outsideOwnedRoot(let path):
                "The sign-in workspace resolved outside OpenUsage's owned directory: \(path)"
            case .symlinkedComponent(let path):
                "OpenUsage can't use a symbolic link in its sign-in workspace: \(path)"
            }
        }
    }

    /// Application Support 또는 주입 base의 parent를 trust anchor로 사용 — 앱 소유 root부터 하위 component까지 symlink 거부.
    let baseDirectory: URL
    private let rootDirectoriesToValidate: [URL]
    private let fileManager: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectory {
            let standardizedBase = baseDirectory.standardizedFileURL
            self.baseDirectory = standardizedBase
            self.rootDirectoriesToValidate = [standardizedBase]
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
            let openUsageDirectory = applicationSupport
                .appendingPathComponent("OpenUsage", isDirectory: true)
                .standardizedFileURL
            let accountSignInDirectory = openUsageDirectory
                .appendingPathComponent("AccountSignIn", isDirectory: true)
                .standardizedFileURL
            self.baseDirectory = accountSignInDirectory
            self.rootDirectoriesToValidate = [openUsageDirectory, accountSignInDirectory]
        }
    }

    func directory(family: String, profileID: String, attemptID: String? = nil) throws -> URL {
        try validate(family)
        try validate(profileID)
        if let attemptID { try validate(attemptID) }
        let directory = baseDirectory
            .appendingPathComponent(family, isDirectory: true)
            .appendingPathComponent(profileID, isDirectory: true)
        guard let attemptID else { return directory }
        return directory.appendingPathComponent(attemptID, isDirectory: true)
    }

    /// 사용자 전용 workspace 생성(전 단계 `0700`) — symlink가 앱 소유 root를 탈출하는 경로는 거부.
    @discardableResult
    func prepare(family: String, profileID: String, attemptID: String? = nil) throws -> URL {
        let directory = try directory(family: family, profileID: profileID, attemptID: attemptID)
        try assertNoSymlinkComponents(family: family, profileID: profileID, attemptID: attemptID)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedRoot = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedDirectory == resolvedRoot || resolvedDirectory.hasPrefix(resolvedRoot + "/") else {
            throw WorkspaceError.outsideOwnedRoot(resolvedDirectory)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    /// Codex 로그인은 기존 인증을 폐기하므로, 저장·전환용 사본과 분리된 빈 작업 공간 사용.
    func prepareReauthentication(family: String, profileID: String) throws -> (attemptID: String?, directory: URL) {
        let attemptID = family == "codex" ? UUID().uuidString : nil
        return (attemptID, try prepare(family: family, profileID: profileID, attemptID: attemptID))
    }

    func assertNoSymlinkComponents(family: String, profileID: String, attemptID: String? = nil) throws {
        let familyDirectory = baseDirectory.appendingPathComponent(family, isDirectory: true)
        let profileDirectory = familyDirectory.appendingPathComponent(profileID, isDirectory: true)
        var directories = rootDirectoriesToValidate + [familyDirectory, profileDirectory]
        if let attemptID {
            directories.append(profileDirectory.appendingPathComponent(attemptID, isDirectory: true))
        }
        for current in directories {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: current.path)
                guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
                    throw WorkspaceError.symlinkedComponent(current.path)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                throw error
            }
        }
    }

    /// 지정한 계정 또는 로그인 시도의 작업 공간만 삭제 — Shared Runtime Home·역사적 `~/.claude-*`/`~/.codex-*` 디렉터리는 범위 밖.
    func remove(family: String, profileID: String, attemptID: String? = nil) throws {
        let directory = try directory(family: family, profileID: profileID, attemptID: attemptID)
        try assertNoSymlinkComponents(family: family, profileID: profileID, attemptID: attemptID)
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
