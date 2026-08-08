import Foundation

struct CodexTokens: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var idToken: String?
    var accountID: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case accountID = "account_id"
    }
}

struct CodexAuth: Codable, Hashable, Sendable {
    var tokens: CodexTokens?
    var lastRefresh: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
        case apiKey = "OPENAI_API_KEY"
    }
}

struct CodexAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file(path: String)
        case keychain
        case accountSnapshot(profileID: String)
    }

    var auth: CodexAuth
    var source: Source

    /// 비어 있지 않은 OAuth access token 보유 여부 — `refresh()` probe와 `hasLocalCredentials()`가 공유하는 단일 기준 (drift 방지).
    var hasUsableAccessToken: Bool {
        auth.tokens?.accessToken?.isEmpty == false
    }
}

enum CodexAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenConflict
    case tokenRevoked
    case tokenExpired
    case usageAPIKey
    case invalidAuthPayload

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `codex` to authenticate."
        case .sessionExpired:
            return "Session expired. Run `codex` to log in again."
        case .tokenConflict:
            return "Token conflict. Run `codex` to log in again."
        case .tokenRevoked:
            return "Token revoked. Run `codex` to log in again."
        case .tokenExpired:
            return "Token expired. Run `codex` to log in again."
        case .usageAPIKey:
            return "Usage not available for API key."
        case .invalidAuthPayload:
            return "Codex auth data is invalid."
        }
    }

    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenConflict, .tokenRevoked, .tokenExpired:
            return true
        case .notLoggedIn, .usageAPIKey, .invalidAuthPayload:
            return false
        }
    }
}

/// `CodexAuthStore`가 볼 수 있는 login의 범위. `.standard`는 기본 카드 (`CODEX_HOME`, 기본 home 목록, 공유 keychain item).
/// `.home`은 managed-profile 계정 카드 전용 — keychain·environment·기본 home fallback 없이 생성 당시의 login 하나만 접근. (`ClaudeCredentialScope` mirror.)
enum CodexCredentialScope: Hashable, Sendable {
    case standard
    /// 등록된 launch-profile home 하나 — `<path>/auth.json`만 읽기.
    case home(path: String)
    /// 저장된 계정 전환 credential — dashboard usage 카드 전용.
    case accountSnapshot(profileID: String)
}

struct CodexAuthStore: Sendable {
    static let keychainService = "Codex Auth"
    /// JWT `exp` 기준 refresh 선행 window — `codex` CLI와 동일한 5분 slack으로 같은 일정에 회전.
    static let accessTokenRefreshWindow: TimeInterval = 5 * 60
    private static let authFile = "auth.json"
    private static let defaultAuthHomes = ["~/.config/codex", "~/.codex"]

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date
    let scope: CodexCredentialScope

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        scope: CodexCredentialScope = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.scope = scope
        self.now = now
    }

    func loadAuthCandidates() -> [CodexAuthState] {
        if case .accountSnapshot(let profileID) = scope {
            return [loadAccountSnapshot(profileID: profileID)].compactMap { $0 }
        }
        return authPaths().compactMap { loadAuth(at: $0) }
    }

    /// 단일 auth 파일에서 credential 읽기 — 이미 로드한 source의 재로드용, 후보 경로 전체 재스캔 없음.
    /// 파일 누락·판독 불가·token 없는 auth는 `nil`.
    func loadAuth(at path: String) -> CodexAuthState? {
        guard files.exists(path),
              let text = try? files.readText(path),
              let auth = Self.parseAuth(text),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .file(path: path))
    }

    func loadKeychainAuth() -> CodexAuthState? {
        // scoped 카드는 공유 "Codex Auth" item 접근 금지 — 다른 카드의 login이고, 읽기만으로도 Keychain prompt 유발 가능.
        guard case .standard = scope else { return nil }
        guard let value = try? keychain.readGenericPassword(service: Self.keychainService),
              let auth = Self.parseAuth(value),
              Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .keychain)
    }

    func save(_ state: CodexAuthState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = state.source.isFile ? [.prettyPrinted, .sortedKeys] : []
        let data = try encoder.encode(state.auth)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexAuthError.invalidAuthPayload
        }

        switch state.source {
        case .file(let path):
            try files.writeText(path, text)
        case .keychain:
            try keychain.writeGenericPassword(service: Self.keychainService, value: text)
        case .accountSnapshot(let profileID):
            try AccountCredentialVault(keychain: keychain).replaceCredential(
                text,
                family: "codex",
                profileID: profileID
            )
        }
    }

    /// Access token의 선제 refresh 필요 여부 — JWT `exp` 우선, `codex` CLI와 동일 판정.
    /// 8일 wall-clock age는 `exp` 미판독 token 전용 fallback — 단독 적용 시 유효한 token까지 refresh해 `refresh_token_reused` 유발 (issue #516).
    func needsRefresh(_ auth: CodexAuth) -> Bool {
        if let accessToken = auth.tokens?.accessToken,
           let expiresAt = accessTokenExpiresAt(accessToken) {
            return expiresAt.timeIntervalSince(now()) <= Self.accessTokenRefreshWindow
        }
        guard let lastRefresh = auth.lastRefresh,
              let date = OpenUsageISO8601.date(from: lastRefresh)
        else {
            return false
        }
        return now().timeIntervalSince(date) > 8 * 24 * 60 * 60
    }

    /// JWT `exp` claim 기준 access token 만료 시각 — decode 불가하거나 `exp` 없으면 `nil`.
    func accessTokenExpiresAt(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func authPaths() -> [String] {
        // scoped 카드는 자기 home만 읽기 — 환경 변수 override와 기본 home 목록은 기본 카드의 login 소유.
        if case .home(let path) = scope {
            return [joinPath(path, Self.authFile)]
        }
        if case .accountSnapshot = scope {
            return []
        }
        if let codexHome = codexHome() {
            return [joinPath(codexHome, Self.authFile)]
        }
        return Self.defaultAuthHomes.map { joinPath($0, Self.authFile) }
    }

    func loadAccountSnapshot(profileID: String) -> CodexAuthState? {
        guard let entry = try? AccountCredentialVault(keychain: keychain).load(
            family: "codex",
            profileID: profileID
        ),
        let auth = Self.parseAuth(entry.credential),
        Self.hasTokenLikeAuth(auth)
        else {
            return nil
        }
        return CodexAuthState(auth: auth, source: .accountSnapshot(profileID: profileID))
    }

    func codexHome() -> String? {
        guard let codexHome = environment.value(for: "CODEX_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !codexHome.isEmpty
        else {
            return nil
        }
        return codexHome
    }

    static func parseAuth(_ text: String) -> CodexAuth? {
        ProviderParse.decodeJSONWithHexFallback(text, as: CodexAuth.self)
    }

    static func hasTokenLikeAuth(_ auth: CodexAuth) -> Bool {
        if auth.tokens?.accessToken?.isEmpty == false { return true }
        if auth.apiKey?.isEmpty == false { return true }
        return false
    }

    private func joinPath(_ base: String, _ leaf: String) -> String {
        base.trimmingTrailingSlashes + "/" + leaf
    }
}

private extension CodexAuthState.Source {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}
