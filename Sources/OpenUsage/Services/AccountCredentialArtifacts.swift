import CryptoKit
import Darwin
import Foundation

/// 공유 인증의 원본·예상 결과 — 원문·메타데이터 보존, Claude 일반 설정은 인증 비교에서 제외.
struct AccountCredentialArtifacts: @unchecked Sendable {
    struct FileState: Codable, Equatable, Sendable {
        var data: Data?
        var permissions: Int?
        var modificationDate: Date?
    }

    enum Snapshot: Codable, Equatable, Sendable {
        case claude(
            scopedCredential: String?, baseCredential: String?, credentialFile: FileState,
            localState: FileState, rootState: FileState
        )
        case codex(authFile: FileState)

        var family: String {
            switch self {
            case .claude: "claude"
            case .codex: "codex"
            }
        }

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            switch (lhs, rhs) {
            case let (.claude(leftScoped, leftBase, leftCredential, leftLocal, leftRoot),
                      .claude(rightScoped, rightBase, rightCredential, rightLocal, rightRoot)):
                return leftScoped.map { Data($0.utf8) } == rightScoped.map { Data($0.utf8) }
                    && leftBase.map { Data($0.utf8) } == rightBase.map { Data($0.utf8) }
                    && leftCredential == rightCredential && leftLocal == rightLocal && leftRoot == rightRoot
            case let (.codex(left), .codex(right)):
                return left == right
            default:
                return false
            }
        }
    }

    enum Error: LocalizedError {
        case changedAuthentication
        case invalidState(URL)

        var errorDescription: String? {
            switch self {
            case .changedAuthentication:
                "The shared sign-in changed during account recovery. Its current credentials were left unchanged."
            case .invalidState(let url):
                "The saved account state could not be restored: \(url.path)"
            }
        }
    }

    private let keychain: any KeychainAccessing
    private let fileManager: FileManager
    private let environment: any EnvironmentReading
    private let homeDirectory: URL

    init(
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        fileManager: FileManager = .default,
        environment: any EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    func capture(family: String, allowInteraction: Bool = true) throws -> Snapshot {
        switch family {
        case "claude":
            return try .claude(
                scopedCredential: readKeychain(service: scopedService, allowInteraction: allowInteraction),
                baseCredential: readKeychain(service: baseService, allowInteraction: allowInteraction),
                credentialFile: readFile(at: sharedHome(family).appendingPathComponent(".credentials.json")),
                localState: readFile(at: sharedHome(family).appendingPathComponent(".claude.json")),
                rootState: readFile(at: homeDirectory.appendingPathComponent(".claude.json"))
            )
        case "codex":
            return try .codex(authFile: readFile(at: sharedHome(family).appendingPathComponent("auth.json")))
        default:
            throw AccountCredentialSwitcher.Error.unsupportedFamily(family)
        }
    }

    func applying(_ entry: AccountCredentialVault.Entry, to original: Snapshot) throws -> Snapshot {
        let credential = FileState(data: Data(entry.credential.utf8), permissions: 0o600, modificationDate: nil)
        switch original {
        case .claude(_, _, _, let localState, let rootState):
            return try .claude(
                scopedCredential: entry.credential, baseCredential: entry.credential,
                credentialFile: credential,
                localState: merging(entry.claudeOAuthAccount, into: localState,
                                    at: sharedHome("claude").appendingPathComponent(".claude.json")),
                rootState: merging(entry.claudeOAuthAccount, into: rootState,
                                   at: homeDirectory.appendingPathComponent(".claude.json"))
            )
        case .codex:
            return .codex(authFile: credential)
        }
    }

    /// 인증 바이트·항목 부재만 비교 — Claude 설정 파일은 oauthAccount만 대상.
    func matches(_ expected: Snapshot, allowInteraction: Bool = true) throws -> Bool {
        let current = try capture(family: expected.family, allowInteraction: allowInteraction)
        return keychainBytes(current) == keychainBytes(expected)
            && authenticationFiles(current) == authenticationFiles(expected)
    }

    func authenticationDigest(of snapshot: Snapshot) throws -> String {
        let data = try JSONEncoder().encode([keychainBytes(snapshot), authenticationFiles(snapshot)])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func canRestore(
        _ original: Snapshot, replacing target: Snapshot, allowInteraction: Bool = true
    ) throws -> Bool {
        guard original.family == target.family else { return false }
        let current = try capture(family: original.family, allowInteraction: allowInteraction)
        let originalValues = keychainBytes(original)
        let targetValues = keychainBytes(target)
        let originalFiles = authenticationFiles(original)
        let targetFiles = authenticationFiles(target)
        return keychainBytes(current).enumerated().allSatisfy { index, value in
            value == originalValues[index] || value == targetValues[index]
        } && authenticationFiles(current).enumerated().allSatisfy { index, value in
            value == originalFiles[index] || value == targetFiles[index]
        }
    }

    /// 전환이 남긴 값만 원복 — 외부 로그인은 복구 중에도 다시 확인하며 그대로 유지.
    func restore(
        _ original: Snapshot, replacing target: Snapshot, allowInteraction: Bool = true
    ) throws {
        AccountCredentialMutationLock.acquire(family: original.family)
        defer { AccountCredentialMutationLock.release(family: original.family) }
        guard try canRestore(original, replacing: target, allowInteraction: allowInteraction) else {
            throw Error.changedAuthentication
        }
        var firstError: (any Swift.Error)?
        func attempt(_ operation: () throws -> Void) throws {
            do {
                try operation()
            } catch {
                if case Error.changedAuthentication = error { throw error }
                if firstError == nil { firstError = error }
                AppLog.error(.auth, "account credential artifact rollback failed: \(error.localizedDescription)")
            }
        }
        let services = original.family == "claude" ? [scopedService, baseService] : []
        let oldValues = keychainValues(original)
        let targetValues = keychainValues(target)
        for (index, service) in services.enumerated() {
            try attempt {
                let current = try readKeychain(service: service, allowInteraction: allowInteraction)
                guard current.map({ Data($0.utf8) }) != oldValues[index].map({ Data($0.utf8) }) else { return }
                guard current.map({ Data($0.utf8) }) == targetValues[index].map({ Data($0.utf8) }) else {
                    throw Error.changedAuthentication
                }
                if let value = oldValues[index] {
                    try keychain.writeCLISharedPassword(service: service, value: value, forCurrentUser: true)
                } else {
                    try keychain.deleteGenericPasswordForCurrentUser(service: service)
                }
            }
        }
        let oldFiles = fileStates(original)
        let targetFiles = fileStates(target)
        for (index, url) in fileURLs(original.family).enumerated() {
            try attempt {
                let current = try readFile(at: url)
                guard current != oldFiles[index] else { return }
                let isClaudeState = original.family == "claude" && index > 0
                let currentAuth = authenticationData(current, isClaudeState: isClaudeState)
                let originalAuth = authenticationData(oldFiles[index], isClaudeState: isClaudeState)
                let targetAuth = authenticationData(targetFiles[index], isClaudeState: isClaudeState)
                if currentAuth == originalAuth, currentAuth != targetAuth { return }
                guard currentAuth == targetAuth else { throw Error.changedAuthentication }
                let restored = try restoredFile(
                    oldFiles[index], replacing: current, target: targetFiles[index],
                    isClaudeState: isClaudeState, at: url
                )
                try restoreFile(restored, replacing: current, at: url)
            }
        }
        if let firstError { throw firstError }
    }

    private func readKeychain(service: String, allowInteraction: Bool) throws -> String? {
        try keychain.readAppOwnedPassword(
            service: service, forCurrentUser: true, allowInteraction: allowInteraction
        )
    }

    private func readFile(at url: URL) throws -> FileState {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return FileState(data: nil, permissions: nil, modificationDate: nil)
        }
        return try FileState(
            data: Data(contentsOf: url),
            permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue,
            modificationDate: attributes[.modificationDate] as? Date
        )
    }

    private func restoreFile(_ original: FileState, replacing current: FileState, at url: URL) throws {
        guard let data = original.data else {
            try fileManager.removeItem(at: url)
            return
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".openusage-restore-\(UUID().uuidString)")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }
        var descriptorIsOpen = true
        defer { if descriptorIsOpen { _ = Darwin.close(descriptor) } }
        defer { try? fileManager.removeItem(at: temporary) }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        var attributes: [FileAttributeKey: Any] = [:]
        if let permissions = original.permissions { attributes[.posixPermissions] = permissions }
        if let modificationDate = original.modificationDate { attributes[.modificationDate] = modificationDate }
        try fileManager.setAttributes(attributes, ofItemAtPath: temporary.path)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }
        guard try readFile(at: url).data == current.data else { throw Error.changedAuthentication }
        let result = temporary.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else { throw Self.currentPOSIXError() }
    }

    private func merging(_ account: String?, into original: FileState, at url: URL) throws -> FileState {
        guard let account else { return original }
        let oauthAccount = try JSONSerialization.jsonObject(with: Data(account.utf8))
        var state: [String: Any]
        if let data = original.data {
            guard String(data: data, encoding: .utf8) != nil,
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Error.invalidState(url) }
            state = parsed
        } else {
            state = ["hasCompletedOnboarding": true]
        }
        state["oauthAccount"] = oauthAccount
        return try FileState(
            data: JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
            permissions: 0o600, modificationDate: nil
        )
    }

    private var scopedService: String {
        ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome("claude").path, environment: environment
        )
    }

    private var baseService: String { ClaudeAuthStore.baseKeychainServiceName(environment: environment) }

    private func sharedHome(_ family: String) -> URL { homeDirectory.appendingPathComponent(".\(family)") }

    private func keychainValues(_ snapshot: Snapshot) -> [String?] {
        switch snapshot {
        case .claude(let scoped, let base, _, _, _): [scoped, base]
        case .codex: []
        }
    }

    private func keychainBytes(_ snapshot: Snapshot) -> [Data?] {
        keychainValues(snapshot).map { $0.map { Data($0.utf8) } }
    }

    private func fileStates(_ snapshot: Snapshot) -> [FileState] {
        switch snapshot {
        case .claude(_, _, let credential, let local, let root): [credential, root, local]
        case .codex(let auth): [auth]
        }
    }

    private func authenticationFiles(_ snapshot: Snapshot) -> [Data?] {
        fileStates(snapshot).enumerated().map { index, file in
            authenticationData(file, isClaudeState: snapshot.family == "claude" && index > 0)
        }
    }

    private func authenticationData(_ file: FileState, isClaudeState: Bool) -> Data? {
        guard isClaudeState, let data = file.data,
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return file.data }
        guard let account = state["oauthAccount"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["oauthAccount": account], options: [.sortedKeys])
    }

    private func restoredFile(
        _ original: FileState, replacing current: FileState, target: FileState,
        isClaudeState: Bool, at url: URL
    ) throws -> FileState {
        guard isClaudeState, current.data != target.data, current.data != original.data else { return original }
        guard let data = current.data,
              var state = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidState(url)
        }
        let oldState = try original.data.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        state["oauthAccount"] = oldState?["oauthAccount"]
        var restored = current
        restored.data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return restored
    }

    private func fileURLs(_ family: String) -> [URL] {
        let home = sharedHome(family)
        if family == "claude" {
            return [home.appendingPathComponent(".credentials.json"),
                    homeDirectory.appendingPathComponent(".claude.json"),
                    home.appendingPathComponent(".claude.json")]
        }
        return [home.appendingPathComponent("auth.json")]
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
