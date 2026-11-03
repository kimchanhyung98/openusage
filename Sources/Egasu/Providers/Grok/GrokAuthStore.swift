import Foundation

struct GrokAuthEntry: Codable, Hashable, Sendable {
    var key: String?
    var refreshToken: String?
    var refresh: String?
    var idToken: String?
    var expiresAt: String?
    var expires: String?
    var oidcClientID: String?

    enum CodingKeys: String, CodingKey {
        case key
        case refreshToken = "refresh_token"
        case refresh
        case idToken = "id_token"
        case expiresAt = "expires_at"
        case expires
        case oidcClientID = "oidc_client_id"
    }
}

struct GrokAuthState: Hashable, Sendable {
    var auth: [String: GrokAuthEntry]
    var entryKey: String
    var entry: GrokAuthEntry
    var token: String
    /// 형제 entry 변경과 구분하는 원본 대상 문서 — 미모델 필드까지 포함, 메모리에서만 유지.
    var entryRevision: Data? = nil
}

enum GrokAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidAuth
    case expired
    case credentialsChanged
    case credentialReadFailed

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Grok not logged in. Run `grok login`."
        case .invalidAuth:
            return "Grok auth invalid. Run `grok login` again."
        case .expired:
            return "Grok auth expired. Run `grok login` again."
        case .credentialsChanged:
            return "Grok sign-in changed while refreshing. Refresh again to use the current account."
        case .credentialReadFailed:
            return "Grok sign-in could not be read. Check access to ~/.grok/auth.json and refresh again."
        }
    }
}

struct GrokAuthStore: Sendable {
    static let authPath = "~/.grok/auth.json"
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let refreshBuffer: TimeInterval = 5 * 60
    private static let mutationLock = NSLock()

    var files: TextFileAccessing
    var now: @Sendable () -> Date

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.files = files
        self.now = now
    }

    func loadAuthCandidates() throws -> [GrokAuthState] {
        guard files.exists(Self.authPath),
              let text = try? files.readText(Self.authPath),
              let auth = Self.parseAuth(text),
              let document = Self.parseJSONObject(text)
        else {
            throw GrokAuthError.notLoggedIn
        }

        let candidates = try auth.compactMap { entryKey, entry -> GrokAuthState? in
            guard let token = trimmed(entry.key),
                  let entryObject = document[entryKey] as? [String: Any] else { return nil }
            return GrokAuthState(
                auth: auth, entryKey: entryKey, entry: entry, token: token,
                entryRevision: try Self.revision(of: entryObject)
            )
        }

        guard !candidates.isEmpty else {
            throw GrokAuthError.invalidAuth
        }
        return candidates
    }

    /// 앱 내부 비교·쓰기 직렬화 — 외부 CLI와의 원자적 조건부 쓰기는 보장하지 않음.
    @discardableResult
    func save(_ state: GrokAuthState) throws -> GrokAuthState {
        Self.mutationLock.lock()
        defer { Self.mutationLock.unlock() }
        guard let expected = state.entryRevision else { throw GrokAuthError.credentialsChanged }
        let currentText: String?
        do {
            currentText = try files.readTextIfPresent(Self.authPath)
        } catch {
            AppLog.error(LogTag.auth("grok"), "credential verification before saving failed: \(error.localizedDescription)")
            throw GrokAuthError.credentialReadFailed
        }
        guard let existingText = currentText,
              var authObject = Self.parseJSONObject(existingText),
              var entryObject = authObject[state.entryKey] as? [String: Any],
              try Self.revision(of: entryObject) == expected else {
            throw GrokAuthError.credentialsChanged
        }
        entryObject["key"] = state.entry.key
        if let refreshToken = state.entry.refreshToken {
            entryObject["refresh_token"] = refreshToken
        }
        if let idToken = state.entry.idToken {
            entryObject["id_token"] = idToken
        }
        if let expiresAt = state.entry.expiresAt {
            entryObject["expires_at"] = expiresAt
        }
        authObject[state.entryKey] = entryObject

        guard JSONSerialization.isValidJSONObject(authObject) else {
            throw GrokAuthError.invalidAuth
        }
        let data = try JSONSerialization.data(withJSONObject: authObject, options: [.prettyPrinted, .sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw GrokAuthError.invalidAuth
        }
        try files.writeText(Self.authPath, text)
        var saved = state
        saved.auth[state.entryKey] = state.entry
        saved.entryRevision = try Self.revision(of: entryObject)
        return saved
    }

    func needsRefresh(entry: GrokAuthEntry, token: String) -> Bool {
        let entryNeedsRefresh = entryExpiresAt(entry).map(needsRefresh(expiresAt:)) ?? false
        let tokenNeedsRefresh = tokenExpiresAt(token).map(needsRefresh(expiresAt:)) ?? false
        return entryNeedsRefresh || tokenNeedsRefresh
    }

    func isExpired(entry: GrokAuthEntry, token: String) -> Bool {
        guard let expiresAt = tokenExpiresAt(token) ?? entryExpiresAt(entry) else {
            return false
        }
        return now() >= expiresAt
    }

    func refreshToken(for entry: GrokAuthEntry) -> String? {
        trimmed(entry.refreshToken) ?? trimmed(entry.refresh)
    }

    func clientID(entryKey: String, entry: GrokAuthEntry) -> String {
        if let oidcClientID = trimmed(entry.oidcClientID) {
            return oidcClientID
        }
        let parts = entryKey.split(separator: "::", omittingEmptySubsequences: false)
        if let last = parts.last {
            let value = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return Self.defaultClientID
    }

    func tokenExpiresAt(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    static func parseAuth(_ text: String) -> [String: GrokAuthEntry]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: GrokAuthEntry].self, from: data)
    }

    static func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func entryExpiresAt(_ entry: GrokAuthEntry) -> Date? {
        if let expiresAt = trimmed(entry.expiresAt), let date = OpenUsageISO8601.date(from: expiresAt) {
            return date
        }
        if let expires = trimmed(entry.expires), let date = OpenUsageISO8601.date(from: expires) {
            return date
        }
        return nil
    }

    private func needsRefresh(expiresAt: Date) -> Bool {
        expiresAt.timeIntervalSince(now()) <= Self.refreshBuffer
    }

    private static func revision(of entry: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
