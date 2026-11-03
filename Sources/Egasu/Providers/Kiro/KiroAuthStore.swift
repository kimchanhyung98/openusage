import Foundation

struct KiroAuth: Sendable, Equatable {
    var accessToken: String
    var expiresAt: Date
    var profileArn: String
}

struct KiroAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/kiro-cli/data.sqlite3"
    static let socialTokenKey = "kirocli:social:token"
    static let profileKey = "api.codewhisperer.profile"

    var sqlite: SQLiteAccessing

    init(sqlite: SQLiteAccessing = SQLiteCLIAccessor()) {
        self.sqlite = sqlite
    }

    func loadAuth() throws -> KiroAuth? {
        let tokenJSON: String?
        do {
            tokenJSON = try sqlite.queryValue(
                path: Self.stateDBPath,
                sql: "SELECT value FROM auth_kv WHERE key = '\(Self.socialTokenKey)' LIMIT 1;"
            )
        } catch {
            throw KiroAuthError.credentialsUnreadable
        }
        guard let tokenJSON else { return nil }
        guard let object = Self.jsonObject(tokenJSON),
              let accessToken = Self.string(object["access_token"]),
              let expiryText = Self.string(object["expires_at"]),
              let expiresAt = OpenUsageISO8601.date(from: expiryText)
        else {
            throw KiroAuthError.credentialsInvalid
        }

        let profileArn: String
        if let embedded = Self.string(object["profile_arn"]) {
            profileArn = embedded
        } else {
            profileArn = try loadFallbackProfileArn()
        }
        return KiroAuth(accessToken: accessToken, expiresAt: expiresAt, profileArn: profileArn)
    }

    func isUsable(_ auth: KiroAuth, now: Date) -> Bool {
        auth.accessToken.nilIfEmpty != nil
            && auth.profileArn.nilIfEmpty != nil
            && auth.expiresAt > now
    }

    private func loadFallbackProfileArn() throws -> String {
        let profileJSON: String?
        do {
            profileJSON = try sqlite.queryValue(
                path: Self.stateDBPath,
                sql: "SELECT value FROM state WHERE key = '\(Self.profileKey)' LIMIT 1;"
            )
        } catch {
            throw KiroAuthError.credentialsUnreadable
        }
        guard let profileJSON,
              let object = Self.jsonObject(profileJSON),
              let arn = Self.string(object["arn"])
        else {
            throw KiroAuthError.missingProfile
        }
        return arn
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
