import CryptoKit
import Foundation

struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsFile: Codable, Hashable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeCredentialState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case accountSnapshot(profileID: String)
        case desktop
        case environment

        /// 로그 안전 source 종류 — keychain service 이름·토큰 노출 금지.
        var label: String {
            switch self {
            case .file: "file"
            case .keychainCurrentUser: "keychainCurrentUser"
            case .keychainLegacy: "keychainLegacy"
            case .accountSnapshot: "accountSnapshot"
            case .desktop: "desktop"
            case .environment: "environment"
            }
        }
    }

    var oauth: ClaudeOAuth
    var source: Source
    var fullData: ClaudeCredentialsFile?
    var inferenceOnly: Bool

    /// 공백 아닌 access token 보유 여부 — `refresh()` 필터와 `hasLocalCredentials()`가 공유하는 단일 "usable" 정의.
    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 기본(info) 로그용 진단 라벨 — source 종류 + refresh token 유무 + 만료 여부만 포함.
    /// 토큰 값·credential blob 노출 금지; `refresh=no`는 만료 자가 복구 불가의 근거(#738).
    func diagnosticsLabel(now: Date) -> String {
        let refresh = (oauth.refreshToken?.isEmpty == false) ? "yes" : "no"
        let expired: String
        if let expiresAt = oauth.expiresAt {
            expired = expiresAt <= now.timeIntervalSince1970 * 1000 ? "yes" : "no"
        } else {
            expired = "unknown"
        }
        return "\(source.label) refresh=\(refresh) expired=\(expired)"
    }
}

/// 유효 probe 순서의 토큰 보유 credential 후보 집합 — inference 전용 environment 토큰은 제외,
/// 선택에 영향 가능한 저장 후보는 전부 유지.
struct ClaudeCredentialGeneration: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let oauth: ClaudeOAuth
        let source: ClaudeCredentialState.Source

        init(_ state: ClaudeCredentialState) {
            oauth = state.oauth
            source = state.source
        }
    }

    var candidates: [Candidate]

    init(_ states: [ClaudeCredentialState]) {
        candidates = states
            .filter { $0.hasUsableAccessToken && !$0.inferenceOnly }
            .map(Candidate.init)
    }

    func replacing(_ state: ClaudeCredentialState) -> Self {
        var updated = self
        guard let index = updated.candidates.firstIndex(where: { $0.source == state.source }) else {
            fatalError("live usage source missing from Claude credential generation")
        }
        updated.candidates[index] = Candidate(state)
        return updated
    }
}

struct ClaudeCredentialLoad: Sendable {
    var candidates: [ClaudeCredentialState]
    var desktopStatus: ClaudeDesktopCredentialStatus
}

enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case desktopPermissionRequired
    case desktopTokenExpired
    case desktopCredentialsUnavailable
    case sessionExpired
    case tokenExpired
    case credentialsChanged
    case invalidOAuthURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .desktopPermissionRequired:
            return "Claude Desktop login found. Refresh once and choose Always Allow to connect it."
        case .desktopTokenExpired:
            return "Claude Desktop login is stale. Open Claude Desktop, then refresh OpenUsage."
        case .desktopCredentialsUnavailable:
            return "Claude Desktop login couldn't be read. Open Claude Desktop, then try again."
        case .sessionExpired:
            return "Session expired. Run `claude` to log in again."
        case .tokenExpired:
            return "Token expired. Run `claude` to log in again."
        case .credentialsChanged:
            return "Claude login changed during refresh. Refresh again."
        case .invalidOAuthURL(let value):
            return "Invalid Claude OAuth URL: \(value). Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
        }
    }

    /// source 하나의 실패가 다음 source로 폴백 가능한지 여부 — 토큰 만료/폐기 계열만 허용.
    /// 외부 `claude` 재로그인이 다른 source에 남긴 새 토큰을 stale 토큰이 가리면 안 됨.
    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenExpired, .desktopTokenExpired:
            return true
        case .notLoggedIn, .desktopPermissionRequired, .desktopCredentialsUnavailable,
             .credentialsChanged, .invalidOAuthURL:
            return false
        }
    }
}

struct ClaudeOAuthConfig: Hashable, Sendable {
    var usageURL: URL
    var refreshURL: URL
    var clientID: String
}

/// `ClaudeAuthStore`가 볼 수 있는 로그인 범위. `.standard`는 기본 카드(기존 동작 그대로);
/// 나머지는 cross-account·environment 토큰·Desktop 폴백 없이 생성된 로그인 하나만 조회.
enum ClaudeCredentialScope: Hashable, Sendable {
    case standard
    /// 추가 `CLAUDE_CONFIG_DIR` home 하나. `keychainLiteral`은 keychain 항목 이름을 만드는
    /// 해시 원문 — Claude Code는 env 값을 입력된 표기 그대로 해시(`~/…` vs 절대 경로 상이).
    case configDir(path: String, keychainLiteral: String)
    /// 저장된 계정 전환 credential — 토큰 rotation은 공유 Claude home이 아닌 전용 snapshot에 기록.
    case accountSnapshot(profileID: String)
}

struct ClaudeAuthStore: Sendable {
    private static let defaultClaudeHome = "~/.claude"
    private static let credentialFileName = ".credentials.json"
    private static let keychainServicePrefix = "Claude Code"
    private static let prodBaseAPIURL = "https://api.anthropic.com"
    private static let prodRefreshURL = "https://platform.claude.com/v1/oauth/token"
    private static let prodClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let nonProdClientID = "22422756-60c9-4084-8eb7-27705fd5cf9a"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var desktop: ClaudeDesktopAuthStore
    var now: @Sendable () -> Date
    let scope: ClaudeCredentialScope
    /// `.standard` store의 Claude Desktop credential 폴백 허용 여부. 추가 계정 카드가 생기면
    /// catalog가 OFF — Desktop 로그인의 소속 카드를 몰라 다른 계정 카드에 usage가 섞일 수 있음.
    let allowsDesktopFallback: Bool
    /// 관리 전환이 `~/.claude`를 Shared Runtime Home으로 소유할 때 true — ambient
    /// `CLAUDE_CONFIG_DIR`를 무시하고 정확히 그 home(기본 keychain service + credential 파일)만 조회.
    let pinsSharedHome: Bool

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        desktop: ClaudeDesktopAuthStore? = nil,
        scope: ClaudeCredentialScope = .standard,
        allowsDesktopFallback: Bool = true,
        pinsSharedHome: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.desktop = desktop ?? ClaudeDesktopAuthStore(files: files, now: now)
        self.scope = scope
        self.allowsDesktopFallback = allowsDesktopFallback
        self.pinsSharedHome = pinsSharedHome
        self.now = now
    }

    /// 디스크/keychain의 credential source 전부를 keychain-우선 고정 순서로 반환 — refresh 루프의 폴백 순회용.
    /// 매 refresh마다 재조회, 메모리 캐시 없음.
    func loadCredentialSet(
        allowDesktopInteraction: Bool = false,
        forceDesktopFallback: Bool = false
    ) -> ClaudeCredentialLoad {
        var stored = orderedStoredCandidates()
        var desktopStatus: ClaudeDesktopCredentialStatus = .notChecked
        // CLI 로그인이 source of truth, Desktop은 폴백 전용 — `.configDir` 카드는 Desktop 미조회(다른 카드의 로그인).
        let desktopAllowed = scope == .standard && allowsDesktopFallback
        if forceDesktopFallback, !desktopAllowed {
            // 안전한 Desktop 후보 없음을 알려 원래 CLI auth 에러 보존 — generic "not logged in" 변환 방지.
            desktopStatus = .notFound
        }
        let hasUsableCLILogin = stored.contains {
            $0.hasUsableAccessToken && liveUsageAvailability($0) == .available
        }
        if desktopAllowed, forceDesktopFallback || !hasUsableCLILogin {
            let result = desktop.load(allowInteraction: allowDesktopInteraction)
            desktopStatus = result.status
            if let oauth = result.oauth {
                stored.insert(ClaudeCredentialState(
                    oauth: oauth,
                    source: .desktop,
                    fullData: nil,
                    inferenceOnly: false
                ), at: 0)
            }
        }

        let candidates = applyingEnvironmentToken(to: stored)
        return ClaudeCredentialLoad(candidates: candidates, desktopStatus: desktopStatus)
    }

    func loadCredentialCandidates() -> [ClaudeCredentialState] {
        loadCredentialSet().candidates
    }

    /// keychain secret을 읽지 않는 로컬 로그인 흔적 확인 — 매 실행 seeding probe(`NewProviderSeeder`)용,
    /// 권한 dialog 발생 금지. `.standard` 카드는 `ClaudeProvider.hasLocalCredentials`의 확장 probe 사용.
    func hasCredentialFootprint() -> Bool {
        switch scope {
        case .standard:
            return !loadCredentialSet().candidates.isEmpty
        case .configDir:
            if files.exists(credentialsPath()) { return true }
            return keychainServiceCandidates().contains {
                keychain.genericPasswordExists(service: $0) == true
            }
        case .accountSnapshot(let profileID):
            return keychain.genericPasswordExists(
                service: AccountCredentialVault.service(family: "claude", profileID: profileID)
            ) == true
        }
    }

    private func applyingEnvironmentToken(to stored: [ClaudeCredentialState]) -> [ClaudeCredentialState] {
        // ambient env 토큰은 DEFAULT 로그인 소유 — scoped 카드 상속 금지(계정 간 토큰 누출).
        guard case .standard = scope else { return stored }
        guard let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN") else {
            return stored
        }
        // 명시적 `CLAUDE_CODE_OAUTH_TOKEN`은 inference 전용(usage endpoint 403) — 라이브 usage 가능한
        // 저장 로그인을 우선, env 토큰은 후순위 inference 전용 폴백. 저장 로그인 부재 시 유일 후보.
        let liveCapable = stored.filter { liveUsageAvailability($0) == .available }
        // plan 메타데이터는 실제 우선되는 credential에서 차용, source는 `.environment`로 정직하게 표기 —
        // 진단 로그가 실제 source를 가리키고 `save()`가 env 토큰을 keychain에 쓰지 않도록.
        let base = liveCapable.first ?? stored.first
        var oauth = base?.oauth ?? ClaudeOAuth()
        oauth.accessToken = envAccessToken
        let envCandidate = ClaudeCredentialState(
            oauth: oauth,
            source: .environment,
            fullData: base?.fullData,
            inferenceOnly: true
        )
        return liveCapable.isEmpty ? [envCandidate] : liveCapable + [envCandidate]
    }

    func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1000 <= 5 * 60 * 1000
    }

    func credentialGeneration(forceDesktopFallback: Bool = false) -> ClaudeCredentialGeneration {
        ClaudeCredentialGeneration(loadCredentialSet(forceDesktopFallback: forceDesktopFallback).candidates)
    }

    /// 유효 후보 집합이 그대로일 때만 OAuth rotation 저장 — generation 전체 비교로 상위 source 추가까지 감지.
    /// 저장소에 원자적 compare-and-swap이 없어 best-effort.
    func save(_ state: ClaudeCredentialState, ifUnchanged expected: ClaudeCredentialGeneration) throws -> Bool {
        guard credentialGeneration() == expected else { return false }
        var fullData = state.fullData ?? ClaudeCredentialsFile()
        fullData.claudeAiOauth = state.oauth
        let data = try JSONEncoder().encode(fullData)
        guard let text = String(data: data, encoding: .utf8) else { return false }

        switch state.source {
        case .file:
            try files.writeText(credentialsPath(), text)
        case .keychainCurrentUser(let service):
            try keychain.writeGenericPasswordForCurrentUser(service: service, value: text)
        case .keychainLegacy(let service):
            try keychain.writeGenericPassword(service: service, value: text)
        case .accountSnapshot(let profileID):
            try AccountCredentialVault(keychain: keychain).replaceCredential(
                text,
                family: "claude",
                profileID: profileID
            )
        case .desktop:
            return false
        case .environment:
            return false
        }
        // credential blob·토큰 로깅 금지 — rotation 발생 사실과 대상 source만 기록.
        AppLog.debug(LogTag.auth("claude"), "persisted rotated credentials (source=\(state.source.label))")
        return true
    }

    /// credential의 라이브 usage endpoint(`/api/oauth/usage`) 호출 가능 여부 — usage 조회에는 `user:profile` scope 필요.
    enum LiveUsageAvailability: Equatable, Sendable {
        case available
        /// 명시적 `CLAUDE_CODE_OAUTH_TOKEN` — 설계상 inference 전용, spend 타일은 로컬 로그로 유지.
        case inferenceOnlyToken
        /// `user:profile` scope 없는 저장 로그인 — `claude` 재로그인 전까지 session/weekly 바 조회 불가.
        case missingProfileScope
    }

    /// usage endpoint 필수 scope — 없으면 inference 인증만 가능.
    static let usageScope = "user:profile"

    func liveUsageAvailability(_ state: ClaudeCredentialState) -> LiveUsageAvailability {
        if state.inferenceOnly { return .inferenceOnlyToken }
        // scopes 필드 이전의 구버전 credential은 "unknown, allow" 처리 — 권한 있는 토큰의 usage 억제 방지(없으면 403이 loudly 표면화).
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return .available }
        return scopes.contains(Self.usageScope) ? .available : .missingProfileScope
    }

    func claudeHomeOverride() -> String? {
        pinsSharedHome ? nil : envText("CLAUDE_CONFIG_DIR")
    }

    // URL 검증 전의 resolved OAuth endpoint 문자열 — suffix는 URL 유효성과 무관해 non-throwing keychain 경로에서 사용 가능.
    private struct ResolvedOAuthEndpoints {
        var baseAPI: String
        var refreshURL: String
        var clientID: String
        var suffix: String
    }

    private func resolveOAuthEndpoints() -> ResolvedOAuthEndpoints {
        Self.resolveOAuthEndpoints(environment: environment)
    }

    private static func resolveOAuthEndpoints(environment: EnvironmentReading) -> ResolvedOAuthEndpoints {
        var baseAPI = Self.prodBaseAPIURL
        var refreshURL = Self.prodRefreshURL
        var clientID = Self.prodClientID
        var suffix = ""

        let isAntUser = envText(environment, "USER_TYPE") == "ant"
        if isAntUser, envFlag(environment, "USE_LOCAL_OAUTH") {
            let base = (envText(environment, "CLAUDE_LOCAL_OAUTH_API_BASE") ?? "http://localhost:8000").trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-local-oauth"
        } else if isAntUser, envFlag(environment, "USE_STAGING_OAUTH") {
            baseAPI = "https://api-staging.anthropic.com"
            refreshURL = "https://platform.staging.ant.dev/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-staging-oauth"
        }

        if let custom = envText(environment, "CLAUDE_CODE_CUSTOM_OAUTH_URL") {
            let base = custom.trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            suffix = "-custom-oauth"
        }
        if let override = envText(environment, "CLAUDE_CODE_OAUTH_CLIENT_ID") {
            clientID = override
        }

        return ResolvedOAuthEndpoints(baseAPI: baseAPI, refreshURL: refreshURL, clientID: clientID, suffix: suffix)
    }

    /// 이 환경의 Claude Code가 쓰는 keychain service 이름 — scoped store와 config-dir discovery의
    /// 단일 원천(비프로덕션 OAuth suffix로 인한 probe/refresh 이름 불일치 방지).
    static func baseKeychainServiceName(environment: EnvironmentReading) -> String {
        "\(keychainServicePrefix)\(resolveOAuthEndpoints(environment: environment).suffix)-credentials"
    }

    static func scopedKeychainServiceName(forConfigDirLiteral literal: String, environment: EnvironmentReading) -> String {
        "\(baseKeychainServiceName(environment: environment))-\(hashSuffix(literal))"
    }

    // env 유래 URL은 system-boundary 입력 — 잘못된 값은 loudly 실패. force-unwrap 금지,
    // prod 폴백 금지(오설정 은폐 + 사용자 토큰의 production 전송 위험).
    func oauthConfig() throws -> ClaudeOAuthConfig {
        let endpoints = resolveOAuthEndpoints()
        let usageURLString = "\(endpoints.baseAPI)/api/oauth/usage"
        guard let usageURL = URL(string: usageURLString) else {
            throw ClaudeAuthError.invalidOAuthURL(usageURLString)
        }
        guard let refreshURL = URL(string: endpoints.refreshURL) else {
            throw ClaudeAuthError.invalidOAuthURL(endpoints.refreshURL)
        }
        return ClaudeOAuthConfig(
            usageURL: usageURL,
            refreshURL: refreshURL,
            clientID: endpoints.clientID
        )
    }

    func keychainServiceCandidates() -> [String] {
        // suffix만 필요(실패 없음) — throwing URL 경로와 분리해 커스텀 OAuth URL 오류에도 credential 로딩 유지.
        let base = "\(Self.keychainServicePrefix)\(resolveOAuthEndpoints().suffix)-credentials"
        switch scope {
        case .configDir(_, let keychainLiteral):
            // 이 카드의 항목만 — 기본 service는 다른 계정의 로그인.
            return ["\(base)-\(hashSuffix(keychainLiteral))"]
        case .standard:
            if let configDir = claudeHomeOverride() {
                return ["\(base)-\(hashSuffix(configDir))", base]
            }
            return [base]
        case .accountSnapshot:
            return []
        }
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    /// keychain-우선 고정 순서의 credential 후보. keychain이 macOS의 source of truth — stale 파일이
    /// 늦은 만료 시각만으로 keychain을 앞서면 안 됨(#738); 파일 폴백은 refresh 루프 담당(#687).
    private func orderedStoredCandidates() -> [ClaudeCredentialState] {
        if case .accountSnapshot(let profileID) = scope {
            return [loadAccountSnapshot(profileID: profileID)].compactMap { $0 }
        }
        var candidates: [ClaudeCredentialState] = []
        if let keychain = loadKeychainCredentials() { candidates.append(keychain) }
        if let file = loadFileCredentials() { candidates.append(file) }

        if candidates.count > 1 {
            let labels = candidates.map(\.source.label).joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (keychain first): \(labels)")
        } else if let only = candidates.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(only.source.label)")
        }
        return candidates
    }

    private func loadFileCredentials() -> ClaudeCredentialState? {
        let path = credentialsPath()
        guard files.exists(path),
              let text = try? files.readText(path),
              let parsed = Self.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(oauth: oauth, source: .file, fullData: parsed, inferenceOnly: false)
    }

    private func loadKeychainCredentials() -> ClaudeCredentialState? {
        // service 이름은 로그 가능; 반환된 credential blob·OAuth 토큰 로깅 금지.
        for service in keychainServiceCandidates() {
            if let state = credentialState(
                from: try? keychain.readGenericPasswordForCurrentUser(service: service),
                service: service, source: .keychainCurrentUser(service: service)
            ) {
                return state
            }
            if let state = credentialState(
                from: try? keychain.readGenericPassword(service: service),
                service: service, source: .keychainLegacy(service: service)
            ) {
                return state
            }
            AppLog.debug(.keychain, "read miss service=\(service)")
        }
        return nil
    }

    private func loadAccountSnapshot(profileID: String) -> ClaudeCredentialState? {
        guard let entry = try? AccountCredentialVault(keychain: keychain).load(
            family: "claude",
            profileID: profileID
        ),
        let parsed = Self.parseCredentials(entry.credential),
        let oauth = parsed.claudeAiOauth,
        oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(
            oauth: oauth,
            source: .accountSnapshot(profileID: profileID),
            fullData: parsed,
            inferenceOnly: false
        )
    }

    /// keychain 히트 1건을 credential state로 파싱 — 부재/손상/토큰 없음이면 `nil`.
    /// keychain 읽기 자체는 호출부 유지 — 읽기 순서와 에러 처리 보존.
    private func credentialState(
        from value: String?,
        service: String,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let value,
              let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        AppLog.debug(.keychain, "read hit service=\(service)")
        return ClaudeCredentialState(oauth: oauth, source: source, fullData: parsed, inferenceOnly: false)
    }

    private func credentialsPath() -> String {
        if case .configDir(let path, _) = scope {
            return "\(path)/\(Self.credentialFileName)"
        }
        return "\(claudeHomeOverride() ?? Self.defaultClaudeHome)/\(Self.credentialFileName)"
    }

    private func envText(_ name: String) -> String? {
        Self.envText(environment, name)
    }

    private static func envText(_ environment: EnvironmentReading, _ name: String) -> String? {
        guard let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func envFlag(_ name: String) -> Bool {
        Self.envFlag(environment, name)
    }

    private static func envFlag(_ environment: EnvironmentReading, _ name: String) -> Bool {
        guard let value = envText(environment, name)?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    private func hashSuffix(_ value: String) -> String {
        Self.hashSuffix(value)
    }

    private static func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
