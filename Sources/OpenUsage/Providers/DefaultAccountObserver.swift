import Foundation

/// family의 DEFAULT home에 로그인된 account를 읽는 관찰자 — account-first 모델의 proven identity 슬라이스, candidate 스캔 없음.
/// identity key는 provider 자신의 account metadata에서만 나옴 — 스스로 이름을 못 대는 account는 추측 없이 `unresolved` 처리.
struct DefaultAccountObserver: Sendable {
    /// 이번 launch에서의 한 family default-home 판독 결과.
    enum Outcome: Equatable, Sendable {
        case resolved(identityKey: String, label: String?, anchor: String)
        /// credential 흔적은 있지만 account 특정 불가 (keyring-mode Codex, 콤마 목록 `CLAUDE_CONFIG_DIR`, account id 없는 legacy auth file).
        case unresolved(reason: String)
        case absent
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    /// 관리형 account 전환이 `~/.claude`를 Shared Runtime Home으로 소유 — ambient `CLAUDE_CONFIG_DIR`가 다른 디렉토리를 가리켜도 그 home에서 identity 해석.
    var pinsClaudeSharedHome: Bool
    /// 관리형 account 전환이 Codex를 shared `~/.codex/auth.json`에 고정 — keychain 항목과 legacy `~/.config/codex` home은 다음 snapshot을 만들 수 없으므로 배제.
    var pinsCodexSharedHome: Bool

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        pinsClaudeSharedHome: Bool = false,
        pinsCodexSharedHome: Bool = false
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.pinsClaudeSharedHome = pinsClaudeSharedHome
        self.pinsCodexSharedHome = pinsCodexSharedHome
    }

    /// 주입된 home 기준으로 선행 `~` 확장 — 테스트가 실제 home을 건드리지 않도록 함.
    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    // MARK: - Claude

    /// Claude Code의 per-install 상태 파일 — 로그인된 account를 명시 (`oauthAccount`).
    struct ClaudeStateFile: Codable {
        struct OAuthAccount: Codable {
            var accountUuid: String?
            var emailAddress: String?
            var organizationUuid: String?
            var organizationName: String?
        }

        var oauthAccount: OAuthAccount?
    }

    /// Claude identity key: account UUID + (있으면) org UUID.
    /// plan은 org 단위 — 같은 account 아래 두 org는 서로 다른 usage pool이므로 절대 병합 금지.
    static func claudeIdentityKey(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        guard let uuid = account.accountUuid?.nilIfEmpty?.lowercased() else { return nil }
        guard let org = account.organizationUuid?.nilIfEmpty?.lowercased() else { return uuid }
        return "\(uuid)|\(org)"
    }

    /// 둘 다 알 때 "email (Org Name)" — 같은 email의 두 로그인을 구분하는 기준은 org.
    static func claudeIdentityLabel(_ account: ClaudeStateFile.OAuthAccount) -> String? {
        let email = account.emailAddress?.nilIfEmpty
        guard let org = account.organizationName?.nilIfEmpty else { return email }
        return email.map { "\($0) (\(org))" } ?? org
    }

    /// 기본 Claude home 관찰 — `ClaudeAuthStore`의 해석과 동일 (`CLAUDE_CONFIG_DIR` export 시 그 경로, 아니면 `~/.claude`).
    /// 콤마 목록은 하나의 identity로 귀속 불가.
    func observeClaude() -> Outcome {
        var configDir = "~/.claude"
        var hasConfigDirOverride = false
        if !pinsClaudeSharedHome,
           let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard !raw.contains(",") else {
                return .unresolved(reason: "CLAUDE_CONFIG_DIR is a comma-separated list")
            }
            configDir = raw
            hasConfigDirOverride = true
        }
        let anchor = expandTilde(configDir)
        // override 없으면 state는 `~/.claude.json`, 명시적 CLAUDE_CONFIG_DIR면 (같은 디렉토리라도) home 내부의 state 파일.
        // pinned mode는 switcher의 two-file 규칙 그대로 — 두 파일이 같은 account를 가리킬 때만 identity 성립.
        let identityPaths: [String] = pinsClaudeSharedHome
            ? [expandTilde("~/.claude.json"), anchor + "/.claude.json"]
            : [hasConfigDirOverride ? anchor + "/.claude.json" : expandTilde("~/.claude.json")]
        var namedAccounts: [(key: String, label: String?)] = []
        var sawStateFile = false
        for identityPath in identityPaths {
            let text: String?
            do {
                text = try files.readTextIfPresent(identityPath)
            } catch {
                return .unresolved(reason: "identity file unreadable: \(error.localizedDescription)")
            }
            guard let text else { continue }
            sawStateFile = true
            guard let parsed = try? JSONDecoder().decode(ClaudeStateFile.self, from: Data(text.utf8)),
                  let account = parsed.oauthAccount,
                  let key = Self.claudeIdentityKey(account)
            else { continue }
            namedAccounts.append((key, Self.claudeIdentityLabel(account)))
        }
        if let first = namedAccounts.first {
            guard namedAccounts.allSatisfy({ $0.key == first.key }) else {
                return .unresolved(reason: "shared home state files name different accounts")
            }
            return .resolved(identityKey: first.key, label: first.label, anchor: anchor)
        }
        if sawStateFile {
            return .unresolved(reason: "identity file present but names no account")
        }
        // state file 없음 — credential file만으로는 귀속 불가, footprint조차 없으면 absent.
        return files.exists(anchor + "/.credentials.json")
            ? .unresolved(reason: "credentials present but no identity file")
            : .absent
    }

    // MARK: - Codex

    /// 기본 Codex home 관찰 — `CodexAuthStore.authPaths()`와 동일 (`CODEX_HOME` export 시 그 경로, 아니면 `~/.config/codex` → `~/.codex`). account를 명시한 첫 home이 승리.
    /// identity는 엄격 — `tokens.account_id` 또는 id_token의 ChatGPT account claim만 인정, 경로 기반 fallback 없음.
    func observeCodex() -> Outcome {
        let homes: [String]
        if pinsCodexSharedHome {
            homes = ["~/.codex"]
        } else if let raw = environment.value(for: "CODEX_HOME")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            homes = [raw]
        } else {
            homes = ["~/.config/codex", "~/.codex"]
        }

        // `CodexProvider.refresh`는 file auth 실패 시 keychain으로 fallback — 항목이 있거나 probe 실패(nil)면 파일 identity를 증명할 수 없어 unresolved 처리. secret은 절대 읽지 않음(attributes-only 존재 probe, 프롬프트 위험 회피).
        // 관리형 전환 모드는 shared auth file 고정이라 fallback이 없으므로 probe 생략.
        if !pinsCodexSharedHome,
           keychain.genericPasswordExists(service: CodexAuthStore.keychainService) != false {
            return .unresolved(reason: "keychain credential present or unverifiable — identity unresolved this launch")
        }

        var sawFootprint = false
        for home in homes {
            let anchor = expandTilde(home)
            let text: String?
            do {
                text = try files.readTextIfPresent(anchor + "/auth.json")
            } catch {
                // 읽기 실패한 auth file도 로그인 footprint — 귀속만 불가.
                sawFootprint = true
                continue
            }
            guard let text else { continue }
            sawFootprint = true
            if let (identityKey, label) = Self.codexFileIdentity(authText: text) {
                return .resolved(identityKey: identityKey, label: label, anchor: anchor)
            }
        }
        return sawFootprint
            ? .unresolved(reason: "credentials present but no account identity")
            : .absent
    }

    /// 엄격한 Codex file identity: `tokens.account_id`, 없으면 id_token의 ChatGPT account claim.
    /// observer·switch transaction·import/migration이 모두 통과하는 단일 규칙 — 한 auth file이 두 가지로 귀속되는 일 방지.
    static func codexFileIdentity(authText: String) -> (identityKey: String, label: String?)? {
        guard let auth = CodexAuthStore.parseAuth(authText),
              auth.tokens?.accessToken?.nilIfEmpty != nil else { return nil }
        let payload = auth.tokens?.idToken.flatMap { ProviderParse.jwtPayload($0) }
        let email = (payload?["email"] as? String)?.nilIfEmpty
        if let accountID = auth.tokens?.accountID?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return (accountID.lowercased(), email)
        }
        if let claimID = chatGPTAccountID(inIDTokenPayload: payload) {
            return (claimID.lowercased(), email)
        }
        return nil
    }

    /// Codex 계정 ID는 namespaced claim을 우선하고 구버전 토큰의 top-level 표기도 허용.
    static func chatGPTAccountID(inIDTokenPayload payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        let authClaim = payload["https://api.openai.com/auth"] as? [String: Any]
        let raw = (authClaim?["chatgpt_account_id"] ?? payload["chatgpt_account_id"]) as? String
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
