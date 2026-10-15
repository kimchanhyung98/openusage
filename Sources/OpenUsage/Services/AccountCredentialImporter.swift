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

        var errorDescription: String? {
            switch self {
            case .noSignIn(let family):
                "No \(family) sign-in was found to import."
            case .identityUnreadable(let family):
                "The current \(family) sign-in doesn't name its account, so it can't be imported."
            case .verificationFailed(let family):
                "The imported \(family) sign-in could not be verified, so nothing was registered."
            }
        }
    }

    let switcher: AccountCredentialSwitcher
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
    nonisolated func readWorkspaceCredential(family: String, profileID: String) throws -> ImportedCredential? {
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
        guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        let staged = AccountProfile(
            id: id ?? UUID().uuidString,
            family: family,
            label: label,
            identityKey: credential.identityKey,
            createdAt: Date()
        )
        do {
            try switcher.writeWorkspaceAuthentication(credential.entry, for: staged)
            try switcher.saveSnapshot(credential.entry, for: staged, allowInteraction: true)
            guard let reloaded = try switcher.loadSnapshot(for: staged, allowInteraction: true),
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
    nonisolated func removeSignInWorkspace(family: String, profileID: String) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        try switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: profileID)
        try workspace.remove(family: family, profileID: profileID)
    }

    /// managed 계정 제거 — switchable snapshot을 잃은 등록 profile 잔존 금지.
    /// workspace 먼저 삭제, 실패 시 snapshot·registry 유지 — registry preflight는 모든 삭제 전 실행.
    func removeAccount(_ profile: AccountProfile, from store: AccountProfilesStore) throws {
        guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        _ = try switcher.recoverInterruptedSwitch(in: store, allowInteraction: true)
        guard try switcher.switchJournal.load(allowInteraction: true) == nil else {
            throw AccountSwitchJournal.Error.pendingTransition
        }
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

    enum ExternalReauthenticationResult: Equatable, Sendable {
        case unchanged
        case noUsableAuthentication
        case updated(profileID: String)
        case recoveredAuthentication
    }

    private struct ExternalClaudeObservation: Sendable {
        var previousSnapshot: AccountCredentialVault.Entry?
        var shared: AccountCredentialVault.Entry
        var identityKey: String
        var sharedNeedsNormalization: Bool
        var originalShared: AccountCredentialArtifacts.Snapshot?
        var allowInteraction: Bool
    }

    /// 선택된 Claude profile에 Shared Runtime Home의 검증된 공식 CLI 로그인을 귀속.
    /// 계정명·stable id·선택 불변, 같은 identity를 가진 다른 profile도 병합하지 않음.
    func reconcileSelectedClaudeSharedAuthentication(
        in store: AccountProfilesStore
    ) throws -> ExternalReauthenticationResult {
        guard !store.isAuthenticationMutationInProgress else { return .unchanged }
        if try switcher.recoverInterruptedSwitch(in: store) { return .recoveredAuthentication }
        if try store.pendingIdentityReplacement() != nil {
            return try recoverInterruptedIdentityReplacement(in: store)
                ? .recoveredAuthentication : .unchanged
        }
        guard let profile = store.preferredProfile(family: "claude") else { return .unchanged }
        guard let observation = try observeExternalClaudeAuthentication(for: profile) else {
            return .noUsableAuthentication
        }
        return try applyExternalClaudeAuthentication(observation, to: profile, in: store)
    }

    /// 런치 후 reconciliation — Keychain 관찰은 main actor 밖에서 실행, 수동 갱신에서만 snapshot 승인 허용.
    func reconcileSelectedClaudeSharedAuthenticationAfterStartup(
        in store: AccountProfilesStore
    ) async throws -> ExternalReauthenticationResult {
        guard !store.isAuthenticationMutationInProgress else { return .unchanged }
        let allowInteraction = ProviderRefreshContext.isManual
        if try await switcher.recoverInterruptedSwitchAfterStartup(
            in: store, allowInteraction: allowInteraction
        ) {
            return .recoveredAuthentication
        }
        guard !store.isAuthenticationMutationInProgress else { return .unchanged }
        if try store.pendingIdentityReplacement() != nil {
            let mutation = try store.beginAuthenticationMutation()
            defer { store.endAuthenticationMutation(mutation, notifyRefresh: false) }
            do {
                return try await recoverIdentityReplacementInteractively(
                    mutation: mutation, in: store, allowInteraction: allowInteraction
                ) ? .recoveredAuthentication : .unchanged
            } catch AccountAuthenticationMutationError.changed {
                AppLog.info(.auth, "deferring account identity replacement recovery after authentication changed")
                return .unchanged
            }
        }
        guard let profile = store.preferredProfile(family: "claude") else { return .unchanged }
        let context = store.authenticationContext()
        let observation = try await Task.detached(priority: .utility) {
            try observeExternalClaudeAuthentication(for: profile, allowInteraction: allowInteraction)
        }.value
        guard let observation else { return .noUsableAuthentication }
        guard !Task.isCancelled, !store.isAuthenticationMutationInProgress,
              store.authenticationContext() == context else { return .unchanged }
        if externalAuthenticationIsUnchanged(observation, profile: profile) { return .unchanged }
        let mutation = try store.beginAuthenticationMutation()
        defer { store.endAuthenticationMutation(mutation, notifyRefresh: false) }
        let transaction = try beginExternalIdentityReplacement(observation, profile: profile, in: store)
        let applyingContext = store.authenticationContext()
        try store.beginApplyingAuthentication(mutation, context: applyingContext)
        do {
            try await loadOffMainActor { try applyExternalCredentialObservation(observation, profile: profile) }
        } catch {
            try store.finishAuthenticationMutation(mutation) {
                try cancelReSignInIfRestored(error, transaction: transaction, in: store)
            }
            throw (error as? ReSignInApplyFailure)?.underlying ?? error
        }
        return try store.finishAuthenticationMutation(mutation) {
            try store.validateAuthenticationContext(applyingContext)
            _ = try store.commitIdentityReplacement(transaction)
            return .updated(profileID: profile.id)
        }
    }

    nonisolated private func observeExternalClaudeAuthentication(
        for profile: AccountProfile, allowInteraction: Bool = false
    ) throws -> ExternalClaudeObservation? {
        let previousSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
        guard let shared = try switcher.readSharedClaudeExternalAuthentication(
            comparedTo: previousSnapshot
        ),
              let identityKey = switcher.identity(of: shared, family: "claude")?.identityKey
        else {
            return nil
        }
        let currentShared = try switcher.readSharedAuthentication(family: "claude")
        let sharedNeedsNormalization = currentShared.flatMap {
            switcher.identity(of: $0, family: "claude")?.identityKey
        } != identityKey
        let originalShared = sharedNeedsNormalization
            ? try switcher.credentialArtifacts.capture(family: "claude", allowInteraction: allowInteraction) : nil
        return ExternalClaudeObservation(
            previousSnapshot: previousSnapshot,
            shared: shared,
            identityKey: identityKey,
            sharedNeedsNormalization: sharedNeedsNormalization,
            originalShared: originalShared,
            allowInteraction: allowInteraction
        )
    }

    private func applyExternalClaudeAuthentication(
        _ observation: ExternalClaudeObservation,
        to profile: AccountProfile,
        in store: AccountProfilesStore
    ) throws -> ExternalReauthenticationResult {
        if externalAuthenticationIsUnchanged(observation, profile: profile) { return .unchanged }
        let transaction = try beginExternalIdentityReplacement(observation, profile: profile, in: store)
        do {
            try applyExternalCredentialObservation(observation, profile: profile)
        } catch {
            try cancelReSignInIfRestored(error, transaction: transaction, in: store)
            throw (error as? ReSignInApplyFailure)?.underlying ?? error
        }
        _ = try store.commitIdentityReplacement(transaction)
        return .updated(profileID: profile.id)
    }

    private func externalAuthenticationIsUnchanged(
        _ observation: ExternalClaudeObservation, profile: AccountProfile
    ) -> Bool {
        observation.previousSnapshot == observation.shared && profile.identityKey == observation.identityKey
            && !observation.sharedNeedsNormalization
    }

    private func beginExternalIdentityReplacement(
        _ observation: ExternalClaudeObservation, profile: AccountProfile, in store: AccountProfilesStore
    ) throws -> AccountIdentityReplacement {
        try store.beginIdentityReplacement(
            profileID: profile.id, with: observation.identityKey,
            replacesSharedAuthentication: observation.sharedNeedsNormalization,
            replacementSnapshotDigest: observation.shared.snapshotDigest(),
            originalSharedAuthenticationDigest: observation.originalShared.map {
                try switcher.credentialArtifacts.authenticationDigest(of: $0)
            }
        )
    }

    nonisolated private func applyExternalCredentialObservation(
        _ observation: ExternalClaudeObservation, profile: AccountProfile
    ) throws {
        try AccountCredentialMutation.withLock {
            try applyLockedExternalCredentialObservation(observation, profile: profile)
        }
    }

    nonisolated private func applyLockedExternalCredentialObservation(
        _ observation: ExternalClaudeObservation, profile: AccountProfile
    ) throws {
        let appliedShared = try observation.originalShared.map {
            try switcher.credentialArtifacts.applying(observation.shared, to: $0)
        }
        var sharedApplyStarted = false
        do {
            try switcher.saveSnapshot(
                observation.shared, for: profile, allowInteraction: observation.allowInteraction
            )
            try switcher.writeWorkspaceAuthentication(observation.shared, for: profile)
            if observation.sharedNeedsNormalization {
                sharedApplyStarted = true
                try switcher.applySharedAuthentication(observation.shared, family: "claude")
                guard let normalized = try switcher.readSharedAuthentication(family: "claude"),
                      switcher.identity(of: normalized, family: "claude")?.identityKey == observation.identityKey
                else {
                    throw ImportError.verificationFailed(family: "claude")
                }
            }
        } catch {
            let restored = rollbackCredentialTransaction(
                profile: profile,
                previousSnapshot: observation.previousSnapshot,
                previousShared: sharedApplyStarted ? observation.originalShared : nil,
                appliedShared: sharedApplyStarted ? appliedShared : nil,
                allowInteraction: observation.allowInteraction,
                context: "external reauthentication"
            )
            throw ReSignInApplyFailure(underlying: error, restored: restored)
        }
    }

    @discardableResult
    nonisolated func rollbackCredentialTransaction(
        profile: AccountProfile,
        previousSnapshot: AccountCredentialVault.Entry?,
        previousShared: AccountCredentialArtifacts.Snapshot? = nil,
        appliedShared: AccountCredentialArtifacts.Snapshot? = nil,
        allowInteraction: Bool = true,
        context: String
    ) -> Bool {
        // 공유 인증 복원 실패 시 새 snapshot 유지 — 재시작에서 journal의 목표 인증으로 완결.
        if let previousShared, let appliedShared {
            do {
                try switcher.credentialArtifacts.restore(
                    previousShared, replacing: appliedShared, allowInteraction: allowInteraction
                )
            } catch {
                AppLog.error(.auth, "\(context) shared-home rollback failed: \(error.localizedDescription)")
                return false
            }
        }
        var restored = true
        if let previousSnapshot {
            do {
                try switcher.writeWorkspaceAuthentication(previousSnapshot, for: profile)
                try switcher.saveSnapshot(previousSnapshot, for: profile, allowInteraction: allowInteraction)
            } catch {
                restored = false
                AppLog.error(.auth, "\(context) snapshot rollback failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try removeSignInWorkspace(family: profile.family, profileID: profile.id)
                try AccountCredentialVault(keychain: keychain).delete(profile: profile)
            } catch {
                restored = false
                AppLog.error(.auth, "\(context) empty-state rollback failed: \(error.localizedDescription)")
            }
        }
        return restored
    }

    /// 첫 계정 import — 이미 로그인된 기본 계정을 provider re-login 없이 registry에 등록.
    /// family에 기본 sign-in 없으면 `nil`(caller가 공식 로그인 제안) — Shared Runtime Home은 read 전용.
    @discardableResult
    func importDefaultAccount(
        family: String,
        label: String = "default",
        into store: AccountProfilesStore
    ) throws -> AccountProfile? {
        guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
        guard store.profiles(family: family).isEmpty else { return nil }
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
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
