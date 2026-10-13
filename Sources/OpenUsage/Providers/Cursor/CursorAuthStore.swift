import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case credentialsChanged

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        case .credentialsChanged:
            return "Cursor sign-in changed while refreshing. Refresh again to use the current account."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60
    private static let keychainMutationLock = NSLock()
    // SQLite 비교도 로더와 같은 Foundation 공백 집합으로 정규화.
    private static let sqliteTrimCharacters: String = {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var scalars = String.UnicodeScalarView()
        for plane in UInt8(0)...16 where whitespace.hasMember(inPlane: plane) {
            let start = UInt32(plane) << 16
            for codePoint in start..<(start + 0x10000) {
                if let scalar = UnicodeScalar(codePoint), whitespace.contains(scalar) {
                    scalars.append(scalar)
                }
            }
        }
        return String(scalars)
    }()

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    func loadAuthState() -> CursorAuthState? {
        let sqliteAccessToken = readStateValue(Self.accessTokenKey)
        let sqliteRefreshToken = readStateValue(Self.refreshTokenKey)
        let sqliteMembershipType = readStateValue(Self.membershipTypeKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let keychainAccessToken = readKeychainValue(Self.keychainAccessTokenService)
        let keychainRefreshToken = readKeychainValue(Self.keychainRefreshTokenService)

        let hasSQLiteAuth = sqliteAccessToken != nil || sqliteRefreshToken != nil
        let hasKeychainAuth = keychainAccessToken != nil || keychainRefreshToken != nil

        if hasSQLiteAuth {
            let sqliteSubject = Self.tokenSubject(sqliteAccessToken)
            let keychainSubject = Self.tokenSubject(keychainAccessToken)
            let subjectsDiffer = sqliteSubject != nil && keychainSubject != nil && sqliteSubject != keychainSubject
            if hasKeychainAuth, sqliteMembershipType == "free", subjectsDiffer {
                return CursorAuthState(
                    accessToken: keychainAccessToken,
                    refreshToken: keychainRefreshToken,
                    source: .keychain
                )
            }

            return CursorAuthState(
                accessToken: sqliteAccessToken,
                refreshToken: sqliteRefreshToken,
                source: .sqlite
            )
        }

        if hasKeychainAuth {
            return CursorAuthState(
                accessToken: keychainAccessToken,
                refreshToken: keychainRefreshToken,
                source: .keychain
            )
        }

        return nil
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    func saveAccessToken(_ accessToken: String, replacing original: CursorAuthState) throws {
        guard original.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
            throw CursorAuthError.credentialsChanged
        }
        switch original.source {
        case .sqlite:
            let changed: Int
            do {
                changed = try sqlite.executeChanges(
                    path: Self.stateDBPath,
                    sql: """
                    INSERT INTO ItemTable (key, value)
                    SELECT ?, ?
                    WHERE NULLIF(TRIM((SELECT value FROM ItemTable WHERE key = ? LIMIT 1), ?), '') IS ?
                      AND NULLIF(TRIM((SELECT value FROM ItemTable WHERE key = ? LIMIT 1), ?), '') IS ?
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """,
                    bindings: [Self.accessTokenKey, accessToken,
                               Self.accessTokenKey, Self.sqliteTrimCharacters, original.accessToken,
                               Self.refreshTokenKey, Self.sqliteTrimCharacters, original.refreshToken]
                )
            } catch {
                guard (try? matchesSQLiteSource(original)) == true else { throw CursorAuthError.credentialsChanged }
                throw error
            }
            guard changed == 1 else { throw CursorAuthError.credentialsChanged }
        case .keychain:
            // 앱 내부 writer의 비교·쓰기를 직렬화 — 외부 Cursor의 Keychain 변경까지 원자화하지 않음.
            Self.keychainMutationLock.lock()
            defer { Self.keychainMutationLock.unlock() }
            let currentAccess: String?
            let currentRefresh: String?
            do {
                currentAccess = try keychain.readGenericPassword(service: Self.keychainAccessTokenService)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                currentRefresh = try keychain.readGenericPassword(service: Self.keychainRefreshTokenService)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            } catch {
                AppLog.error(LogTag.auth("cursor"), "credential verification before saving failed: \(error.localizedDescription)")
                throw CursorAuthError.credentialsChanged
            }
            guard currentAccess == original.accessToken, currentRefresh == original.refreshToken else {
                throw CursorAuthError.credentialsChanged
            }
            try keychain.writeGenericPassword(service: Self.keychainAccessTokenService, value: accessToken)
        }
    }

    private func readStateValue(_ key: String) -> String? {
        try? stateValue(key)
    }

    private func matchesSQLiteSource(_ state: CursorAuthState) throws -> Bool {
        try stateValue(Self.accessTokenKey) == state.accessToken
            && stateValue(Self.refreshTokenKey) == state.refreshToken
    }

    private func stateValue(_ key: String) throws -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readKeychainValue(_ service: String) -> String? {
        guard let value = try? keychain.readGenericPassword(service: service) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
