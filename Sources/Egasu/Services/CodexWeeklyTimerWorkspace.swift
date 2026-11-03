import Darwin
import Foundation

/// 타이머 실행마다 인증·설정·작업 경로 분리, 종료 후 해당 임시 경로만 삭제.
final class CodexWeeklyTimerWorkspace {
    enum WorkspaceError: Error {
        case unsafeDirectory
        case invalidAuth
    }

    let directory: URL
    let home: URL
    let codexHome: URL
    let workingDirectory: URL
    let temporaryDirectory: URL
    private let fileManager: FileManager
    private var lockDescriptor: Int32 = -1

    init(baseDirectory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        try Self.cleanAbandonedWorkspaces(baseDirectory: baseDirectory, fileManager: fileManager)
        directory = baseDirectory.appendingPathComponent(
            "session-\(getpid())-\(UUID().uuidString)", isDirectory: true
        )
        home = directory.appendingPathComponent("home", isDirectory: true)
        codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        workingDirectory = directory.appendingPathComponent("work", isDirectory: true)
        temporaryDirectory = directory.appendingPathComponent("tmp", isDirectory: true)
        do {
            for url in [directory, home, codexHome, workingDirectory, temporaryDirectory] {
                try fileManager.createDirectory(
                    at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
                )
            }
            lockDescriptor = Darwin.open(directory.appendingPathComponent("active.lock").path,
                                         O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
            guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if lockDescriptor >= 0 { Darwin.close(lockDescriptor); lockDescriptor = -1 }
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        if lockDescriptor >= 0 { Darwin.close(lockDescriptor) }
    }

    func writeAuth(_ auth: CodexAuth) throws {
        guard auth.apiKey?.isEmpty != false,
              auth.tokens?.accessToken?.isEmpty == false else {
            throw WorkspaceError.invalidAuth
        }
        let data = try JSONEncoder().encode(auth)
        let url = codexHome.appendingPathComponent("auth.json")
        guard fileManager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError.invalidAuth
        }
    }

    func readAuth() throws -> CodexAuth {
        let url = codexHome.appendingPathComponent("auth.json")
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 1_048_576 else {
            throw WorkspaceError.invalidAuth
        }
        let auth = try JSONDecoder().decode(CodexAuth.self, from: Data(contentsOf: url))
        guard auth.apiKey?.isEmpty != false,
              auth.tokens?.accessToken?.isEmpty == false,
              auth.tokens?.refreshToken?.isEmpty == false,
              auth.tokens?.idToken?.isEmpty == false else {
            throw WorkspaceError.invalidAuth
        }
        return auth
    }

    func remove() throws {
        try fileManager.removeItem(at: directory)
    }

    static func cleanAbandonedWorkspaces(baseDirectory: URL, fileManager: FileManager = .default) throws {
        try prepareRoot(baseDirectory, fileManager: fileManager)
        try removeAbandonedWorkspaces(in: baseDirectory, fileManager: fileManager)
    }

    func environment(executableURL: URL) -> [String: String] {
        [
            "HOME": home.path,
            "CODEX_HOME": codexHome.path,
            "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "TMPDIR": temporaryDirectory.path + "/",
            "PATH": ([executableURL.deletingLastPathComponent().path]
                + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":"),
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        ]
    }

    private static func prepareRoot(_ root: URL, fileManager: FileManager) throws {
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw WorkspaceError.unsafeDirectory
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    /// 실행 중인 작업은 파일 잠금으로 보존 — PID 재사용으로 남은 인증의 정리가 누락되지 않도록 처리.
    private static func removeAbandonedWorkspaces(in root: URL, fileManager: FileManager) throws {
        for url in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            guard name.hasPrefix("session-") else { continue }
            let suffix = name.dropFirst("session-".count)
            guard let separator = suffix.firstIndex(of: "-"),
                  let pid = Int32(suffix[..<separator]), pid > 0,
                  UUID(uuidString: String(suffix[suffix.index(after: separator)...])) != nil else { continue }
            let descriptor = Darwin.open(url.appendingPathComponent("active.lock").path, O_RDWR | O_CLOEXEC)
            if descriptor >= 0 {
                defer { Darwin.close(descriptor) }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                    if errno == EWOULDBLOCK { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                try fileManager.removeItem(at: url)
                continue
            }
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard kill(pid, 0) == -1, errno == ESRCH else { continue }
            try fileManager.removeItem(at: url)
        }
    }
}
