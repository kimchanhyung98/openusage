import Foundation

/// 이미 로그인된 provider 계정을 provider re-login 없이 managed registry로 import — credential read, identity 증명, Keychain·Sign-In Workspace snapshot 후 profile 등록.
/// 취소·실패·identity 부재 read는 아무것도 등록 안 함 — 인증 실패의 조용한 빈 계정화 금지.
@MainActor
struct AccountCredentialImporter {
    struct ImportedCredential: Sendable {
        var entry: AccountCredentialVault.Entry
        var identityKey: String
        var label: String?
    }

    enum ImportError: LocalizedError, Equatable {
        case noSignIn(family: String)
        case identityUnreadable(family: String)
        case verificationFailed(family: String)
        case differentAccount(profileLabel: String)

        var errorDescription: String? {
            switch self {
            case .noSignIn(let family):
                "No \(family) sign-in was found to import."
            case .identityUnreadable(let family):
                "The current \(family) sign-in doesn't name its account, so it can't be imported."
            case .verificationFailed(let family):
                "The imported \(family) sign-in could not be verified, so nothing was registered."
            case .differentAccount(let profileLabel):
                "That sign-in belongs to a different account. \(profileLabel) was left unchanged — add the other account separately."
            }
        }
    }

    private let switcher: AccountCredentialSwitcher
    private let keychain: KeychainAccessing
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let workspace: AccountSignInWorkspace

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        fileManager: FileManager = .default,
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspace: AccountSignInWorkspace = AccountSignInWorkspace()
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.workspace = workspace
        self.switcher = AccountCredentialSwitcher(
            keychain: keychain,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory,
            workspace: workspace
        )
    }

    // MARK: - Reading

    /// Shared Runtime Home의 현재 sign-in — 없으면 `nil`.
    /// Codex는 legacy `~/.config/codex/auth.json`과 `Codex Auth` Keychain item도 1회성 import 소스로 수용 — identity를 증명하는 첫 소스 채택, 디스크 무변경.
    func readDefaultCredential(family: String) throws -> ImportedCredential? {
        var entries: [AccountCredentialVault.Entry] = []
        if let shared = try switcher.readSharedAuthentication(family: family) {
            entries.append(shared)
        }
        if family == "codex" {
            let legacyHome = homeDirectory.appendingPathComponent(".config/codex").path
            if let legacy = try switcher.readAuthentication(family: family, home: legacyHome) {
                entries.append(legacy)
            }
            if let value = try? keychain.readGenericPassword(service: CodexAuthStore.keychainService),
               CodexAuthStore.parseAuth(value)?.tokens?.accessToken?.nilIfEmpty != nil {
                entries.append(AccountCredentialVault.Entry(credential: value, claudeOAuthAccount: nil))
            }
        }
        guard !entries.isEmpty else { return nil }
        // 소스를 순서대로 평가해 identity를 증명하는 첫 소스 사용 — 계정 특정 못 하는 token 형태 소스가 뒤의 유효 소스를 가리는 것 금지.
        for entry in entries {
            if let (identityKey, label) = switcher.identity(of: entry, family: family) {
                return ImportedCredential(entry: entry, identityKey: identityKey, label: label)
            }
        }
        throw ImportError.identityUnreadable(family: family)
    }

    /// profile의 Sign-In Workspace에서 완료된 공식 로그인 — 사용 가능한 credential 없으면 `nil`.
    func readWorkspaceCredential(family: String, profileID: String) throws -> ImportedCredential? {
        let home = try workspace.directory(family: family, profileID: profileID).path
        guard let entry = try switcher.readAuthentication(family: family, home: home) else {
            return nil
        }
        guard let (identityKey, label) = switcher.identity(of: entry, family: family) else {
            throw ImportError.identityUnreadable(family: family)
        }
        return ImportedCredential(entry: entry, identityKey: identityKey, label: label)
    }

    // MARK: - Registration

    /// 증명된 credential을 snapshot하고 profile 등록 — workspace + Keychain 먼저, 원본 identity 재검증 후에만 registry 등록.
    /// 실패 시 staged 산출물 제거 — 아무것도 등록 안 함.
    @discardableResult
    func register(
        _ credential: ImportedCredential,
        family: String,
        label: String,
        id: String? = nil,
        into store: AccountProfilesStore
    ) throws -> AccountProfile {
        if let existing = store.activeProfile(family: family, identityKey: credential.identityKey) {
            throw AccountProfileError.duplicateAccount(existingLabel: existing.label)
        }
        let staged = AccountProfile(
            id: id ?? UUID().uuidString,
            family: family,
            label: label,
            identityKey: credential.identityKey,
            createdAt: Date()
        )
        do {
            try switcher.writeWorkspaceAuthentication(credential.entry, for: staged)
            try switcher.saveSnapshot(credential.entry, for: staged)
            guard let reloaded = try switcher.loadSnapshot(for: staged),
                  switcher.identity(of: reloaded, family: family)?.identityKey == credential.identityKey else {
                throw ImportError.verificationFailed(family: family)
            }
            return try store.add(
                family: family,
                label: uniqueLabel(label, family: family, store: store),
                identityKey: credential.identityKey,
                id: staged.id
            )
        } catch {
            try? AccountCredentialVault(keychain: keychain).delete(profile: staged)
            try? switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: staged.id)
            try? workspace.remove(family: family, profileID: staged.id)
            throw error
        }
    }

    /// profile sign-in workspace에 staged된 전부 삭제 — provider-scoped 로그인 credential 먼저, 다음 workspace 디렉터리 (삭제 순서 계약).
    /// Shared Runtime Home·legacy 디렉터리는 범위 밖.
    func removeSignInWorkspace(family: String, profileID: String) throws {
        try switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: profileID)
        try workspace.remove(family: family, profileID: profileID)
    }

    /// managed 계정 제거 — switchable snapshot을 잃은 등록 profile 잔존 금지.
    /// workspace 먼저 삭제, 실패 시 snapshot·registry 유지 — registry preflight는 모든 삭제 전 실행.
    func removeAccount(_ profile: AccountProfile, from store: AccountProfilesStore) throws {
        try store.validateArchive(profileID: profile.id)
        do {
            try removeSignInWorkspace(family: profile.family, profileID: profile.id)
        } catch {
            throw RemovalError.workspace
        }
        do {
            try AccountCredentialVault(keychain: keychain).delete(profile: profile)
        } catch {
            throw RemovalError.snapshot
        }
        try store.archive(profileID: profile.id)
    }

    enum RemovalError: LocalizedError {
        case workspace
        case snapshot

        var errorDescription: String? {
            switch self {
            case .workspace:
                "OpenUsage couldn't delete this account's sign-in workspace. The account and its saved authentication were not removed — try again."
            case .snapshot:
                "OpenUsage couldn't delete the saved Keychain authentication. The account remains registered and ready, so you can try removing it again."
            }
        }
    }

    /// profile workspace에서 실행된 Sign In Again 완결.
    /// snapshot 교체는 새 credential이 같은 계정을 증명할 때만 — 다른 identity면 기존 snapshot으로 workspace 복원 후 실패, re-login의 조용한 계정 전환 금지.
    /// 활성 profile 재로그인은 Shared Runtime Home도 갱신 — 새 터미널이 즉시 새 credential 사용.
    func completeReSignIn(for profile: AccountProfile, isActive: Bool) throws {
        guard let credential = try readWorkspaceCredential(family: profile.family, profileID: profile.id) else {
            throw ImportError.noSignIn(family: profile.family)
        }
        guard credential.identityKey == profile.identityKey else {
            if let snapshot = try? switcher.loadSnapshot(for: profile) {
                try? switcher.writeWorkspaceAuthentication(snapshot, for: profile)
            }
            throw ImportError.differentAccount(profileLabel: profile.label)
        }
        try switcher.saveSnapshot(credential.entry, for: profile)
        if isActive {
            try switcher.applySharedAuthentication(credential.entry, family: profile.family)
        }
    }

    /// 첫 계정 import — 이미 로그인된 기본 계정을 provider re-login 없이 registry에 등록.
    /// family에 기본 sign-in 없으면 `nil`(caller가 공식 로그인 제안) — Shared Runtime Home은 read 전용.
    @discardableResult
    func importDefaultAccount(
        family: String,
        label: String = "default",
        into store: AccountProfilesStore
    ) throws -> AccountProfile? {
        guard store.profiles(family: family).isEmpty else { return nil }
        guard let credential = try readDefaultCredential(family: family) else { return nil }
        let profile = try register(credential, family: family, label: label, into: store)
        store.setPreferred(family: family, profileID: profile.id)
        return profile
    }

    /// 충돌 없는 첫 label — 요청 label 그대로, 충돌 시 " 2", " 3", ….
    private func uniqueLabel(_ label: String, family: String, store: AccountProfilesStore) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = AccountProfilesStore.isValidLabel(trimmed) ? trimmed : "Account"
        let taken = Set(store.profiles(family: family).map { $0.label.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var attempt = 2
        while taken.contains("\(base) \(attempt)".lowercased()) {
            attempt += 1
        }
        return "\(base) \(attempt)"
    }
}
