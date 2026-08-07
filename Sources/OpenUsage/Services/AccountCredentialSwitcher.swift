import Foundation

/// The one credential-moving path for account switching. It applies exactly one profile's
/// authentication to the family's Shared Runtime Home (`~/.claude`, `~/.codex`) and never touches
/// configuration, MCP, memory, plugins, or session history. Every reader here is also reused by the
/// first-account import, re-login, and registry migration so a second credential parser never
/// exists.
struct AccountCredentialSwitcher {
    enum Error: LocalizedError, Equatable {
        case unsupportedFamily(String)
        case missingSnapshot(String)
        case snapshotIdentityMismatch(String)
        case invalidClaudeState(URL)
        case switchVerificationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFamily(let family):
                "Account switching is not supported for \(family)."
            case .missingSnapshot(let label):
                "No saved sign-in was found for \(label). Sign in again and retry."
            case .snapshotIdentityMismatch(let label):
                "The saved sign-in for \(label) no longer matches its account. Sign in again and retry."
            case .invalidClaudeState(let url):
                "Claude account state is invalid: \(url.path)"
            case .switchVerificationFailed(let label):
                "Switching to \(label) could not be verified, so the previous account was restored."
            }
        }
    }

    private let keychain: KeychainAccessing
    private let fileManager: FileManager
    private let environment: EnvironmentReading
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
        self.environment = environment
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.workspace = workspace
    }

    // MARK: - Switch transaction

    /// The Settings toggle transaction: validate the target snapshot, preserve the rotated
    /// credential of the account that is leaving, apply only the target's authentication to the
    /// Shared Runtime Home, verify the applied identity, and roll back on any failure. Selection
    /// state is the caller's to update — only after this returns.
    func switchAuthentication(to selected: AccountProfile, from current: AccountProfile?) throws {
        guard AccountProfilesStore.isSupportedFamily(selected.family) else {
            throw Error.unsupportedFamily(selected.family)
        }
        // Re-selecting the active profile must not produce a single write.
        guard current?.id != selected.id else { return }

        guard let target = try? loadSnapshot(for: selected) else {
            throw Error.missingSnapshot(selected.label)
        }
        guard identity(of: target, family: selected.family)?.identityKey == selected.identityKey else {
            throw Error.snapshotIdentityMismatch(selected.label)
        }

        // The active credential may have rotated since the current profile was applied. Preserve it
        // to that profile's snapshot and workspace — but only when the shared home still provably
        // belongs to that profile's account.
        let active = try readSharedAuthentication(family: selected.family)
        if let current,
           current.family == selected.family,
           let active,
           identity(of: active, family: current.family)?.identityKey == current.identityKey {
            try saveSnapshot(active, for: current)
            try writeWorkspaceAuthentication(active, for: current)
        }

        do {
            try applySharedAuthentication(target, family: selected.family)
            let applied = try readSharedAuthentication(family: selected.family)
            guard let applied,
                  identity(of: applied, family: selected.family)?.identityKey == selected.identityKey else {
                throw Error.switchVerificationFailed(selected.label)
            }
        } catch {
            if let active {
                do {
                    try applySharedAuthentication(active, family: selected.family)
                } catch {
                    AppLog.error(.auth, "account switch rollback failed: \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    // MARK: - Shared Runtime Home

    /// The one home a family's terminal sessions share — fixed by the switching model, never a
    /// user-editable path.
    func sharedHomePath(family: String) -> String {
        homeDirectory.appendingPathComponent(".\(family)").path
    }

    /// The Shared Runtime Home's current authentication, or `nil` when nothing usable is signed in.
    func readSharedAuthentication(family: String) throws -> AccountCredentialVault.Entry? {
        try readAuthentication(family: family, home: sharedHomePath(family: family))
    }

    /// Reads one home's authentication (the Shared Runtime Home, a Sign-In Workspace, or a legacy
    /// profile home). Claude reads its scoped Keychain credential first — Claude Code's source of
    /// truth on macOS — then the credential file; Codex reads only `auth.json`.
    func readAuthentication(family: String, home: String) throws -> AccountCredentialVault.Entry? {
        switch family {
        case "claude":
            guard let credential = readClaudeCredential(home: home) else { return nil }
            let oauthAccount = try claudeOAuthAccount(inFirstOf: claudeStateReadURLs(for: home))
            return AccountCredentialVault.Entry(credential: credential, claudeOAuthAccount: oauthAccount)
        case "codex":
            let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            guard let text = try readTextIfPresent(url),
                  CodexAuthStore.parseAuth(text)?.tokens?.accessToken?.nilIfEmpty != nil else {
                return nil
            }
            return AccountCredentialVault.Entry(credential: text, claudeOAuthAccount: nil)
        default:
            throw Error.unsupportedFamily(family)
        }
    }

    /// Applies one entry's authentication to the Shared Runtime Home — and nothing else. Claude:
    /// the scoped/base Keychain credential, `.credentials.json`, and the `oauthAccount` key merged
    /// into the state files (all other keys preserved). Codex: an atomic `auth.json` replace.
    func applySharedAuthentication(_ entry: AccountCredentialVault.Entry, family: String) throws {
        let home = sharedHomePath(family: family)
        switch family {
        case "claude":
            try writeClaudeCredential(entry.credential, home: home)
            if let oauthAccount = entry.claudeOAuthAccount {
                for url in claudeStateWriteURLs(for: home) {
                    try mergeClaudeOAuthAccount(oauthAccount, at: url)
                }
            }
        case "codex":
            try writePrivateFile(
                entry.credential,
                to: URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            )
        default:
            throw Error.unsupportedFamily(family)
        }
    }

    // MARK: - Snapshot and workspace

    func loadSnapshot(for profile: AccountProfile) throws -> AccountCredentialVault.Entry? {
        try AccountCredentialVault(keychain: keychain).load(profile: profile)
    }

    func saveSnapshot(_ entry: AccountCredentialVault.Entry, for profile: AccountProfile) throws {
        try AccountCredentialVault(keychain: keychain).save(entry, profile: profile)
    }

    /// Mirrors an entry into the profile's Sign-In Workspace so a later official re-login starts
    /// from the account's freshest credential. Never used as a normal session home.
    func writeWorkspaceAuthentication(_ entry: AccountCredentialVault.Entry, for profile: AccountProfile) throws {
        let directory = try workspace.prepare(family: profile.family, profileID: profile.id)
        switch profile.family {
        case "claude":
            try writePrivateFile(entry.credential, to: directory.appendingPathComponent(".credentials.json"))
            if let oauthAccount = entry.claudeOAuthAccount {
                try mergeClaudeOAuthAccount(oauthAccount, at: directory.appendingPathComponent(".claude.json"))
            }
        case "codex":
            try writePrivateFile(entry.credential, to: directory.appendingPathComponent("auth.json"))
        default:
            throw Error.unsupportedFamily(profile.family)
        }
    }

    // MARK: - Identity

    /// The provider-proven identity carried by an entry, or `nil` when the credential can't name
    /// its account. Copy, switch, and rotation preservation all stop on `nil`.
    func identity(of entry: AccountCredentialVault.Entry, family: String) -> (identityKey: String, label: String?)? {
        switch family {
        case "claude":
            guard ClaudeAuthStore.parseCredentials(entry.credential)?
                .claudeAiOauth?.accessToken?.nilIfEmpty != nil,
                let account = entry.claudeOAuthAccount,
                let decoded = try? JSONDecoder().decode(
                    DefaultAccountObserver.ClaudeStateFile.OAuthAccount.self,
                    from: Data(account.utf8)
                ),
                let key = DefaultAccountObserver.claudeIdentityKey(decoded)
            else { return nil }
            return (key, DefaultAccountObserver.claudeIdentityLabel(decoded))
        case "codex":
            return DefaultAccountObserver.codexFileIdentity(authText: entry.credential)
        default:
            return nil
        }
    }

    // MARK: - Claude plumbing

    private func readClaudeCredential(home: String) -> String? {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home,
            environment: environment
        )
        var services = [scopedService]
        if canonicalPath(home) == canonicalPath(sharedHomePath(family: "claude")) {
            services.append(ClaudeAuthStore.baseKeychainServiceName(environment: environment))
        }
        for service in services {
            if let value = try? keychain.readGenericPasswordForCurrentUser(service: service),
               isValidClaudeCredential(value) {
                return value
            }
            if let value = try? keychain.readGenericPassword(service: service),
               isValidClaudeCredential(value) {
                return value
            }
        }
        let fileURL = URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")
        if let value = try? readTextIfPresent(fileURL), isValidClaudeCredential(value) {
            return value
        }
        return nil
    }

    private func writeClaudeCredential(_ credential: String, home: String) throws {
        try keychain.writeGenericPasswordForCurrentUser(
            service: ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: home,
                environment: environment
            ),
            value: credential
        )
        try keychain.writeGenericPasswordForCurrentUser(
            service: ClaudeAuthStore.baseKeychainServiceName(environment: environment),
            value: credential
        )
        try writePrivateFile(
            credential,
            to: URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")
        )
    }

    /// Where Claude names the shared home's account: the default state next to `~/.claude` first
    /// (plain `claude` runs), then the state inside the home (wrapper runs with an explicit
    /// `CLAUDE_CONFIG_DIR`). A custom home — a workspace or legacy profile home — has only its own.
    private func claudeStateReadURLs(for home: String) -> [URL] {
        let local = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        if canonicalPath(home) == canonicalPath(sharedHomePath(family: "claude")) {
            return [homeDirectory.appendingPathComponent(".claude.json"), local]
        }
        return [local]
    }

    private func claudeStateWriteURLs(for home: String) -> [URL] {
        claudeStateReadURLs(for: home)
    }

    /// The shared home's `oauthAccount`, from the first state file that names one. When BOTH state
    /// files exist and name DIFFERENT accounts (an external login updated only one of them), the
    /// home's identity is ambiguous — return `nil` so preservation and import stop rather than
    /// pairing a credential with the wrong account.
    private func claudeOAuthAccount(inFirstOf urls: [URL]) throws -> String? {
        var accounts: [String] = []
        for url in urls {
            guard let text = try readTextIfPresent(url) else { continue }
            guard let state = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Error.invalidClaudeState(url)
            }
            guard let account = state["oauthAccount"] else { continue }
            let data = try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys])
            accounts.append(String(decoding: data, as: UTF8.self))
        }
        guard let first = accounts.first else { return nil }
        let identityOf: (String) -> String? = { json in
            (try? JSONDecoder().decode(
                DefaultAccountObserver.ClaudeStateFile.OAuthAccount.self,
                from: Data(json.utf8)
            )).flatMap(DefaultAccountObserver.claudeIdentityKey)
        }
        let identities = Set(accounts.compactMap(identityOf))
        guard identities.count <= 1 else {
            AppLog.warn(.auth, "claude state files name different accounts; treating the home's identity as unresolved")
            return nil
        }
        return first
    }

    /// Deletes the provider-scoped login credential a workspace sign-in created. Claude Code on
    /// macOS stores the workspace login in a Keychain item scoped to the `CLAUDE_CONFIG_DIR`
    /// literal; removing an account must clear it or the removed account's tokens outlive the
    /// profile. Codex workspaces are file-only (the launcher forces the file credential store).
    func removeWorkspaceCredentialArtifacts(family: String, profileID: String) throws {
        guard family == "claude" else { return }
        let home = try workspace.directory(family: family, profileID: profileID).path
        try keychain.deleteGenericPassword(
            service: ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: home,
                environment: environment
            )
        )
    }

    /// Merges only the `oauthAccount` key into a Claude state file, preserving every other key. A
    /// missing file gets minimal onboarding-complete state so Claude Code never replays first-run.
    private func mergeClaudeOAuthAccount(_ account: String, at url: URL) throws {
        let oauthAccount = try JSONSerialization.jsonObject(with: Data(account.utf8))
        var state: [String: Any] = [:]
        if let text = try readTextIfPresent(url) {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Error.invalidClaudeState(url)
            }
            state = parsed
        } else {
            state["hasCompletedOnboarding"] = true
        }
        state["oauthAccount"] = oauthAccount
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try writePrivateData(data, to: url)
    }

    // MARK: - Files

    private func readTextIfPresent(_ url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func writePrivateFile(_ text: String, to url: URL) throws {
        try writePrivateData(Data(text.utf8), to: url)
    }

    private func writePrivateData(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isValidClaudeCredential(_ value: String) -> Bool {
        ClaudeAuthStore.parseCredentials(value)?.claudeAiOauth?.accessToken?.nilIfEmpty != nil
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
