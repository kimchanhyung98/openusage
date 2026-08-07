import Foundation

/// Imports an already-signed-in provider account into the managed registry without any provider
/// re-login: read the credential, prove its identity, snapshot it into the Keychain and the
/// profile's Sign-In Workspace, and only then register the profile. Cancelled, failed, or
/// identity-less reads register nothing — an authentication failure is never a silent empty
/// account.
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

    /// The Shared Runtime Home's current sign-in, or `nil` when there is none. Codex also accepts
    /// the legacy `~/.config/codex/auth.json` and the `Codex Auth` Keychain item as one-time import
    /// sources — the first source that proves an identity wins, and nothing on disk is modified.
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
        // Evaluate the sources in order and use the FIRST one that proves an identity; a
        // token-shaped source that can't name its account must not shadow a later one that can.
        for entry in entries {
            if let (identityKey, label) = switcher.identity(of: entry, family: family) {
                return ImportedCredential(entry: entry, identityKey: identityKey, label: label)
            }
        }
        throw ImportError.identityUnreadable(family: family)
    }

    /// A completed official login inside a profile's Sign-In Workspace, or `nil` when the login
    /// left no usable credential there.
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

    /// Snapshots a proven credential and registers its profile: workspace + Keychain first, then a
    /// re-read verification against the original identity, and only then the registry entry. Any
    /// failure removes what was staged and registers nothing.
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

    /// Deletes everything OpenUsage staged for a profile's sign-in workspace: the provider-scoped
    /// login credential first, then the workspace directory. Shared Runtime Homes and legacy
    /// directories are never in scope.
    func removeSignInWorkspace(family: String, profileID: String) throws {
        try switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: profileID)
        try workspace.remove(family: family, profileID: profileID)
    }

    /// Removes a managed account without leaving a registered profile that has already lost its
    /// switchable snapshot. The workspace goes first; if that fails, the snapshot and registry stay
    /// intact. The registry preflight runs before any deletion.
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

    /// Completes a **Sign In Again** that ran in the profile's workspace. The snapshot is replaced
    /// only when the fresh credential proves the SAME account; a different identity restores the
    /// workspace from the existing snapshot and fails, so a re-login can never quietly turn one
    /// profile into another account. Re-signing the active profile also refreshes the Shared
    /// Runtime Home so new terminals pick the new credential up immediately.
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

    /// The first-account import: bring the already-signed-in default account into the registry
    /// without a provider re-login. Returns `nil` when the family has no default sign-in (the
    /// caller then offers the official login). The Shared Runtime Home is read, never written.
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

    /// A first label that reads well and never collides: the requested label, else " 2", " 3", …
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
