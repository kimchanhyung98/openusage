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
}

enum GrokAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case invalidAuth
    case expired

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Grok not logged in. Run `grok login`."
        case .invalidAuth:
            return "Grok auth invalid. Run `grok login` again."
        case .expired:
            return "Grok auth expired. Run `grok login` again."
        }
    }
}

struct GrokAuthStore: Sendable {
    static let authPath = "~/.grok/auth.json"
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    static let refreshBuffer: TimeInterval = 5 * 60

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
              let auth = Self.parseAuth(text)
        else {
            throw GrokAuthError.notLoggedIn
        }

        let candidates = auth.compactMap { entryKey, entry -> GrokAuthState? in
            guard let token = trimmed(entry.key) else { return nil }
            return GrokAuthState(auth: auth, entryKey: entryKey, entry: entry, token: token)
        }

        guard !candidates.isEmpty else {
            throw GrokAuthError.invalidAuth
        }
        return candidates
    }

    func save(_ state: GrokAuthState) throws {
        // 존재하지만 손상·비가독인 auth.json을 in-memory state로 재구성해 덮어쓰기 금지 — 다른 계정 entry가 소실됨
        // 파일이 아예 없는 최초 쓰기만 in-memory state로 seed
        var authObject: [String: Any]
        if files.exists(Self.authPath) {
            guard let existingText = try? files.readText(Self.authPath),
                  let parsed = Self.parseJSONObject(existingText)
            else {
                throw GrokAuthError.invalidAuth
            }
            authObject = parsed
        } else {
            authObject = try Self.jsonObject(from: state.auth)
        }
        var entryObject = authObject[state.entryKey] as? [String: Any] ?? [:]
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

    private static func jsonObject(from auth: [String: GrokAuthEntry]) throws -> [String: Any] {
        // 실패 시 `[:]` 반환 대신 throw — 빈 base면 save()가 현재 entry만 남긴 파일을 써서 다른 계정 credential이 파괴됨
        let data = try JSONEncoder().encode(auth)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokAuthError.invalidAuth
        }
        return object
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
