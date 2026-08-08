import Foundation

/// 기기에 이미 있는 GitHub token — Copilot usage endpoint에 사용 가능.
struct CopilotToken: Hashable, Sendable {
    var value: String
}

enum CopilotAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case tokenInvalid

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Sign in to GitHub Copilot in your editor, or run gh auth login, and try again."
        case .tokenInvalid:
            return "GitHub token invalid or expired. Re-authenticate (gh auth login) and try again."
        }
    }
}

/// Copilot 도구가 기기에 이미 남긴 GitHub token 읽기 — 로그인 flow·브라우저 쿠키 없음. prompt 없는 파일 우선, Keychain 마지막:
/// 1) Copilot 에디터 config `~/.config/github-copilot/apps.json`(구 `hosts.json`) — VS Code/JetBrains/Neovim Copilot 플러그인이 쓰는 OAuth token.
/// 2) GitHub CLI `~/.config/gh/hosts.yml`의 `oauth_token`. 3) GitHub CLI Keychain 항목(service `gh:github.com`) — token을 파일 대신 system keyring에 둘 때, go-keyring 래핑.
struct CopilotAuthStore: Sendable {
    static let editorAppsPath = "~/.config/github-copilot/apps.json"
    static let editorHostsPath = "~/.config/github-copilot/hosts.json"
    static let ghHostsPath = "~/.config/gh/hosts.yml"
    static let ghKeychainService = "gh:github.com"

    var files: TextFileAccessing
    var keychain: KeychainAccessing

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor()
    ) {
        self.files = files
        self.keychain = keychain
    }

    /// 첫 non-empty source 승리. blocking(Keychain) — main actor 밖에서 호출.
    func loadToken() -> CopilotToken? {
        loadFromEditorConfig() ?? loadFromGhConfig() ?? loadFromGhKeychain()
    }

    // MARK: - Sources

    func loadFromEditorConfig() -> CopilotToken? {
        for path in [Self.editorAppsPath, Self.editorHostsPath] {
            guard files.exists(path),
                  let text = try? files.readText(path),
                  let token = Self.oauthToken(fromEditorJSON: text)
            else {
                continue
            }
            return CopilotToken(value: token)
        }
        return nil
    }

    func loadFromGhConfig() -> CopilotToken? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath),
              let token = Self.yamlValue(text, key: "oauth_token")
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    func loadFromGhKeychain() -> CopilotToken? {
        guard let raw = readGhKeychainRaw(),
              let token = ProviderParse.unwrapGoKeyring(raw)
        else {
            return nil
        }
        return CopilotToken(value: token)
    }

    private func readGhKeychainRaw() -> String? {
        // `gh`는 Keychain 항목의 account로 GitHub username 사용 — hosts.yml에서 복구 가능하면 그 account로 조회, 아니면 service 단독 조회로 fallback.
        if let account = ghUsername(),
           let raw = try? keychain.readGenericPassword(service: Self.ghKeychainService, account: account) {
            return raw
        }
        return try? keychain.readGenericPassword(service: Self.ghKeychainService)
    }

    private func ghUsername() -> String? {
        guard files.exists(Self.ghHostsPath),
              let text = try? files.readText(Self.ghHostsPath)
        else {
            return nil
        }
        return Self.yamlValue(text, key: "user")
    }

    // MARK: - Parsing (pure)

    /// Copilot 에디터 config에서 github.com `oauth_token` 추출. 파일은 host로 key된 JSON 객체 — `"github.com"`(구 `hosts.json`) 또는 `"github.com:<appId>"`(신 `apps.json`), 값마다 `oauth_token` 보유.
    /// github.com 항목만 사용: 다른 host(GitHub Enterprise 등)의 token을 api.github.com에 보내면 안 되고, nil 반환으로 chain이 gh config/keychain으로 진행.
    static func oauthToken(fromEditorJSON text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        func token(in value: Any?) -> String? {
            guard let dict = value as? [String: Any],
                  let token = (dict["oauth_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !token.isEmpty
            else {
                return nil
            }
            return token
        }

        for (key, value) in object where key == "github.com" || key.hasPrefix("github.com:") {
            if let token = token(in: value) { return token }
        }
        return nil
    }

    /// GitHub CLI `hosts.yml`의 특정 host 블록 안 들여쓰기된 `key: value` 읽기. `github.com` 블록으로 한정 필수 — 같은 파일의 GitHub Enterprise 블록 `oauth_token`이 api.github.com으로 전송되면 확정 401/403.
    /// 중첩 map인 `users:`는 콜론 위치가 달라 `user:`와 매칭되지 않음.
    static func yamlValue(_ text: String, key: String, host: String = "github.com") -> String? {
        let prefix = key + ":"
        let hostHeader = host + ":"
        var inHost = false
        for line in text.split(whereSeparator: \.isNewline) {
            // 비들여쓰기 줄은 새 최상위 블록(host header 또는 root key) 시작 — github.com 블록의 자식만 읽음.
            if let first = line.first, !first.isWhitespace {
                inHost = line.trimmingCharacters(in: .whitespaces).hasPrefix(hostHeader)
                continue
            }
            guard inHost else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return unquoted.isEmpty ? nil : unquoted
        }
        return nil
    }

}
