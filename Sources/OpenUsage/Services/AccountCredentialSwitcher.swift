import Foundation

/// 계정 전환의 유일한 credential 이동 경로 — 한 profile의 인증만 family의 Shared Runtime Home(`~/.claude`, `~/.codex`)에 적용.
/// configuration·MCP·memory·plugin·세션 history 불변. reader는 첫 import·re-login·registry migration이 재사용 — 제2의 credential parser 금지.
/// 내부 `FileManager` delegate 미사용 — background credential read와 main-actor transaction에서 공유 가능.
struct AccountCredentialSwitcher: @unchecked Sendable {
    enum Error: LocalizedError, Equatable {
        case unsupportedFamily(String)
        case missingSnapshot(String)
        case snapshotIdentityMismatch(String)
        case invalidClaudeState(URL)
        case incompleteClaudeAuthentication
        case conflictingClaudeAuthentication
        case switchVerificationFailed(String)
        case switchRecoveryRequired
        case selectionSaveFailed

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
            case .incompleteClaudeAuthentication:
                "Claude sign-in has not finished updating its account state. Finish signing in and try again."
            case .conflictingClaudeAuthentication:
                "Claude sign-ins in different locations conflict. Open Settings → Accounts → Manage Claude Account, then choose Sign In Again."
            case .switchVerificationFailed(let label):
                "Switching to \(label) could not be verified. Check the selected account and try again."
            case .switchRecoveryRequired:
                "Claude account switch recovery is required. Open Settings → Accounts → Manage Claude Account, then choose the Use Claude option for the account you want to use."
            case .selectionSaveFailed:
                "OpenUsage couldn't save the selected account. The recovery record was kept. Try again."
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

    // MARK: - Shared Runtime Home

    /// family의 터미널 세션이 공유하는 유일한 home — 전환 모델이 고정, 사용자 편집 불가 경로.
    func sharedHomePath(family: String) -> String {
        homeDirectory.appendingPathComponent(".\(family)").path
    }

    /// Shared Runtime Home의 현재 인증 — 사용 가능한 로그인 없으면 `nil`.
    func readSharedAuthentication(family: String) throws -> AccountCredentialVault.Entry? {
        try readAuthentication(family: family, home: sharedHomePath(family: family))
    }

    var switchJournal: AccountSwitchJournal {
        AccountSwitchJournal(path: workspace.baseDirectory.appendingPathComponent("claude-switch.json").path)
    }

    /// 전환 복구의 세대 비교 — 모든 공유 인증 사본을 읽고 읽기 실패를 부재로 바꾸지 않음.
    func readClaudeSwitchState() throws -> AccountSwitchJournal.SharedState {
        let home = sharedHomePath(family: "claude")
        let services = [
            ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: home, environment: environment),
            ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        ]
        var credentials = try services.map { service in
            try keychain.readGenericPasswordForCurrentUser(service: service)
                ?? keychain.readGenericPassword(service: service)
        }
        credentials.append(try readTextIfPresent(URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")))
        let stateURLs = [
            homeDirectory.appendingPathComponent(".claude.json"),
            URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        ]
        let accounts = try stateURLs.map { try claudeOAuthAccount(inFirstOf: [$0]) }
        let credential = credentials.compactMap { $0 }.first(where: isUsableClaudeCredential) ?? ""
        let identities = accounts.map {
            identity(of: .init(credential: credential, claudeOAuthAccount: $0), family: "claude")?.identityKey
        }
        return .init(credentials: credentials, accounts: accounts, identities: identities)
    }

    /// 선택된 Claude의 터미널 준비 상태용 scoped credential + 내부 state 쌍.
    /// 영구 snapshot 교체와 달리 쓰기 세대 검증 없이 현재 CLI가 사용할 로그인만 확인.
    func readSharedClaudeAuthenticationForReadiness() throws -> AccountCredentialVault.Entry? {
        try sharedClaudeAuthentication()?.entry
    }

    /// snapshot 교체용 Claude 로그인 — state가 새 credential을 반영한 완료 상태일 때만 반환.
    /// 정규화 여부도 같은 관찰에서 결정 — 후속 읽기에서 발견한 새 충돌을 덮어쓰기 근거로 사용 금지.
    func readSharedClaudeExternalAuthentication(
        comparedTo previousSnapshot: AccountCredentialVault.Entry?
    ) throws -> (entry: AccountCredentialVault.Entry, requiresNormalization: Bool)? {
        guard let observed = try sharedClaudeAuthentication() else { return nil }
        let authentication = (
            entry: observed.entry,
            requiresNormalization: try claudeSharedNormalizationRequired(for: observed)
        )
        guard observed.entry != previousSnapshot else { return authentication }
        if let previousSnapshot,
           sameClaudeCredentialChain(previousSnapshot, observed.entry) {
            return authentication
        }
        guard let credentialModifiedAt = observed.credentialModifiedAt,
              let stateModifiedAt = observed.stateModifiedAt,
              stateModifiedAt >= credentialModifiedAt
        else {
            AppLog.error(.auth, "shared Claude account state predates its credential; preserving the managed snapshot")
            throw Error.incompleteClaudeAuthentication
        }
        return authentication
    }

    private func sameClaudeCredentialChain(
        _ previous: AccountCredentialVault.Entry,
        _ observed: AccountCredentialVault.Entry
    ) -> Bool {
        guard identity(of: previous, family: "claude")?.identityKey
                == identity(of: observed, family: "claude")?.identityKey,
              let previousRefreshToken = ClaudeAuthStore.parseCredentials(previous.credential)?
                .claudeAiOauth?.refreshToken?.nilIfEmpty,
              let observedRefreshToken = ClaudeAuthStore.parseCredentials(observed.credential)?
                .claudeAiOauth?.refreshToken?.nilIfEmpty
        else {
            return false
        }
        return previousRefreshToken == observedRefreshToken
    }

    private struct SharedClaudeAuthentication {
        var entry: AccountCredentialVault.Entry
        var credentialModifiedAt: Date?
        var stateModifiedAt: Date?
    }

    private func sharedClaudeAuthentication() throws -> SharedClaudeAuthentication? {
        let home = sharedHomePath(family: "claude")
        var service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home,
            environment: environment
        )
        var stateURL = URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        var stored = try claudeKeychainCredential(service: service)
        if stored == nil {
            // 관리형 home의 scoped credential 부재는 로그아웃 — 이전 base 인증으로 복원 금지.
            guard !fileManager.fileExists(atPath: stateURL.path) else { return nil }
            // 최초 등록 전 plain 로그인만 base credential + 루트 state에서 수용.
            service = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
            stateURL = homeDirectory.appendingPathComponent(".claude.json")
            stored = try claudeKeychainCredential(service: service)
        }
        guard let stored, isUsableClaudeCredential(stored.value),
              let account = try claudeOAuthAccount(inFirstOf: [stateURL])
        else { return nil }
        return SharedClaudeAuthentication(
            entry: .init(credential: stored.value, claudeOAuthAccount: account),
            credentialModifiedAt: try stored.isCurrentUser
                ? keychain.genericPasswordModificationDateForCurrentUser(service: service)
                : keychain.genericPasswordModificationDate(service: service),
            stateModifiedAt: try modificationDateIfPresent(stateURL)
        )
    }

    private func claudeKeychainCredential(service: String) throws -> (value: String, isCurrentUser: Bool)? {
        if let value = try keychain.readGenericPasswordForCurrentUser(service: service) {
            return (value, true)
        }
        guard let value = try keychain.readGenericPassword(service: service) else { return nil }
        return (value, false)
    }

    /// 충돌한 기본 로그인은 scoped 인증·state보다 모두 오래됐을 때만 자동 정규화 허용.
    private func claudeSharedNormalizationRequired(for observed: SharedClaudeAuthentication) throws -> Bool {
        let rootState = homeDirectory.appendingPathComponent(".claude.json")
        guard let rootAccount = try claudeOAuthAccount(inFirstOf: [rootState]) else { return false }
        guard let rootIdentity = identity(
            of: .init(credential: observed.entry.credential, claudeOAuthAccount: rootAccount), family: "claude"
        )?.identityKey,
        let observedIdentity = identity(of: observed.entry, family: "claude")?.identityKey else {
            AppLog.error(.auth, "Claude sign-in identity is unresolved; preserving all authentication")
            throw Error.conflictingClaudeAuthentication
        }
        guard rootIdentity != observedIdentity else { return false }

        var conflictingDates = [try modificationDateIfPresent(rootState)]
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        if let base = try claudeKeychainCredential(service: baseService), base.value != observed.entry.credential {
            conflictingDates.append(try base.isCurrentUser
                ? keychain.genericPasswordModificationDateForCurrentUser(service: baseService)
                : keychain.genericPasswordModificationDate(service: baseService))
        }
        guard let credentialDate = observed.credentialModifiedAt,
              let stateDate = observed.stateModifiedAt,
              conflictingDates.allSatisfy({ date in
                  date.map { $0 < min(credentialDate, stateDate) } ?? false
              })
        else {
            AppLog.error(.auth, "conflicting Claude sign-in is newer or its write order is unknown; preserving all authentication")
            throw Error.conflictingClaudeAuthentication
        }
        return true
    }

    /// 한 home의 인증 read (Shared Runtime Home·Sign-In Workspace·legacy profile home).
    /// Claude는 scoped Keychain credential 우선(macOS의 source of truth) 후 credential 파일, Codex는 `auth.json`만.
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

    /// entry의 인증만 Shared Runtime Home에 적용 — 그 외 일체 불변.
    /// Claude: scoped/base Keychain credential + `.credentials.json` + state 파일에 `oauthAccount` 키만 merge(다른 키 보존). Codex: `auth.json` 원자적 교체.
    func applySharedAuthentication(_ entry: AccountCredentialVault.Entry, family: String) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
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

    func loadSnapshot(for profile: AccountProfile, allowInteraction: Bool = false) throws -> AccountCredentialVault.Entry? {
        try AccountCredentialVault(keychain: keychain).load(profile: profile, allowInteraction: allowInteraction)
    }

    func saveSnapshot(_ entry: AccountCredentialVault.Entry, for profile: AccountProfile) throws {
        try AccountCredentialVault(keychain: keychain).save(entry, profile: profile)
    }

    /// entry를 profile의 Sign-In Workspace에 미러링 — 이후 공식 re-login이 최신 credential에서 시작. 일반 세션 home 사용 금지.
    func writeWorkspaceAuthentication(_ entry: AccountCredentialVault.Entry, for profile: AccountProfile) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        let directory = try workspace.prepare(family: profile.family, profileID: profile.id)
        switch profile.family {
        case "claude":
            try keychain.writeCLISharedPassword(
                service: ClaudeAuthStore.scopedKeychainServiceName(
                    forConfigDirLiteral: directory.path,
                    environment: environment
                ),
                value: entry.credential,
                forCurrentUser: true
            )
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

    /// entry가 담은 provider 증명 identity — credential이 계정을 특정 못 하면 `nil`, copy·switch·rotation 보존 모두 `nil`에서 중단.
    func identity(of entry: AccountCredentialVault.Entry, family: String) -> (identityKey: String, label: String?)? {
        switch family {
        case "claude":
            guard isUsableClaudeCredential(entry.credential),
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
               isUsableClaudeCredential(value) {
                return value
            }
            if let value = try? keychain.readGenericPassword(service: service),
               isUsableClaudeCredential(value) {
                return value
            }
        }
        let fileURL = URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")
        if let value = try? readTextIfPresent(fileURL), isUsableClaudeCredential(value) {
            return value
        }
        return nil
    }

    private func writeClaudeCredential(_ credential: String, home: String) throws {
        try keychain.writeCLISharedPassword(
            service: ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: home,
                environment: environment
            ),
            value: credential,
            forCurrentUser: true
        )
        try keychain.writeCLISharedPassword(
            service: ClaudeAuthStore.baseKeychainServiceName(environment: environment),
            value: credential,
            forCurrentUser: true
        )
        try writePrivateFile(
            credential,
            to: URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")
        )
    }

    /// Claude가 shared home 계정을 기록하는 위치 — `~/.claude` 옆 기본 state 우선(plain `claude` 실행), 다음 home 내부 state(wrapper의 명시적 `CLAUDE_CONFIG_DIR` 실행).
    /// custom home(workspace·legacy profile home)은 자체 state만 보유.
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

    /// 계정을 기록한 첫 state 파일의 `oauthAccount`.
    /// 두 state 파일이 서로 다른 계정 기록 시 identity 모호 — `nil` 반환으로 보존·import 중단, credential과 잘못된 계정의 결합 방지.
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

    /// workspace sign-in이 만든 provider-scoped 로그인 credential 삭제.
    /// Claude Code는 `CLAUDE_CONFIG_DIR` literal 스코프의 Keychain item에 로그인 저장 — 미삭제 시 제거된 계정의 token이 profile보다 오래 생존. Codex workspace는 파일 전용.
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

    /// Claude state 파일에 `oauthAccount` 키만 merge, 다른 키 전부 보존 — 파일 부재 시 onboarding-complete 최소 state 생성으로 first-run 재생 방지.
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

    private func modificationDateIfPresent(_ url: URL) throws -> Date? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
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

    private func isUsableClaudeCredential(_ value: String) -> Bool {
        guard let oauth = ClaudeAuthStore.parseCredentials(value)?.claudeAiOauth,
              oauth.accessToken?.nilIfEmpty != nil
        else {
            return false
        }
        guard let expiresAt = oauth.expiresAt,
              expiresAt <= Date().timeIntervalSince1970 * 1_000
        else {
            return true
        }
        return oauth.refreshToken?.nilIfEmpty != nil
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
