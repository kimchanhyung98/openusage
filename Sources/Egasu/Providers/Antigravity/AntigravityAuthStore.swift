import CryptoKit
import Foundation

/// Antigravity가 기기에 이미 가진 credential. 현재 빌드는 OAuth token을 macOS Keychain(service `gemini`, account `antigravity`)에 `go-keyring-base64` 래핑 JSON blob으로 저장 — access token·refresh token·expiry, Antigravity 앱/`agy` CLI가 기록.
/// (구 SQLite `oauthToken` envelope는 더 이상 token을 담지 않아 읽지 않음.)
struct AntigravityKeychainToken: Sendable, Equatable {
    var accessToken: String?
    var refreshToken: String?
    var expiry: Date?
}

struct AntigravityAuthStore: Sendable {
    static let keychainService = "gemini"
    static let keychainAccount = "antigravity"
    /// 갱신된 access token의 자체 cache — Google OAuth refresh를 매 cycle 대신 token 수명당 ~1회로 축소. Antigravity의 keychain 항목에는 절대 쓰지 않음.
    static let cachePath = "~/Library/Application Support/OpenUsage/antigravity/auth.json"
    /// 남은 수명이 이 값 미만인 token은 만료로 취급 (바로 refresh).
    static let refreshBuffer: TimeInterval = 60

    var keychain: KeychainAccessing
    var files: TextFileAccessing
    var now: @Sendable () -> Date

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.keychain = keychain
        self.files = files
        self.now = now
    }

    /// blocking keychain 읽기 — main actor 밖에서 호출.
    func loadKeychainToken() throws -> AntigravityKeychainToken? {
        let raw: String?
        do {
            raw = try keychain.readGenericPassword(
                service: Self.keychainService,
                account: Self.keychainAccount
            )
        } catch {
            AppLog.error(LogTag.auth("antigravity"), "keychain credential read failed")
            throw AntigravityError.credentialStoreUnreadable
        }
        guard let raw else { return nil }
        guard let token = Self.extractToken(fromKeychainRaw: raw) else {
            AppLog.error(LogTag.auth("antigravity"), "keychain credential is malformed")
            throw AntigravityError.invalidCredentialData
        }
        return token
    }

    /// keychain access token이 시도할 가치가 있는지: expiry 미상이거나 아직 지나지 않음.
    func isUsable(expiry: Date?) -> Bool {
        guard let expiry else { return true }
        return expiry.timeIntervalSince(now()) > Self.refreshBuffer
    }

    // MARK: - Refreshed-token cache

    private struct CachedToken: Codable {
        var accessToken: String
        var expiresAtMs: Double
        /// 이 파생 access token을 만든 Keychain refresh credential의 SHA-256. optional인 이유는 구버전 unbound cache 파일이 migration 중 안전한 miss로 decode되게 하기 위함.
        var credentialFingerprint: Data?
    }

    func loadCachedToken(matching source: AntigravityKeychainToken) -> String? {
        guard let expectedFingerprint = Self.credentialFingerprint(for: source.refreshToken) else {
            discardCachedToken()
            return nil
        }
        // keychain token의 `isUsable(expiry:)`와 동일하게 최소 `refreshBuffer`만큼 수명 요구 — 임박 만료 cached token은 거의 확실한 401과 불필요한 refresh만 유발.
        let text: String
        do {
            guard let stored = try files.readTextIfPresent(Self.cachePath) else { return nil }
            text = stored
        } catch {
            AppLog.warn(LogTag.auth("antigravity"), "refreshed-token cache read failed; ignoring it")
            return nil
        }
        guard let cached = try? JSONDecoder().decode(CachedToken.self, from: Data(text.utf8)) else {
            AppLog.warn(LogTag.auth("antigravity"), "refreshed-token cache is malformed; discarding it")
            discardCachedToken()
            return nil
        }
        guard cached.credentialFingerprint == expectedFingerprint,
              cached.expiresAtMs > (now().timeIntervalSince1970 + Self.refreshBuffer) * 1000,
              let token = cached.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            discardCachedToken()
            return nil
        }
        return token
    }

    func cacheToken(_ accessToken: String, expiresIn: Double, sourceRefreshToken: String) {
        guard let credentialFingerprint = Self.credentialFingerprint(for: sourceRefreshToken),
              accessToken.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
            return
        }
        let expiresAtMs = (now().timeIntervalSince1970 + expiresIn) * 1000
        let cached = CachedToken(
            accessToken: accessToken,
            expiresAtMs: expiresAtMs,
            credentialFingerprint: credentialFingerprint
        )
        do {
            let data = try JSONEncoder().encode(cached)
            try files.writeText(Self.cachePath, String(decoding: data, as: UTF8.self))
        } catch {
            // 갱신된 token은 이번 세션에 유효 — cache 실패는 다음 cycle에 다시 refresh할 뿐. live fetch를 실패시키지 않고 크게 로그.
            AppLog.warn(LogTag.auth("antigravity"), "failed to cache refreshed token: \(error.localizedDescription)")
        }
    }

    /// OpenUsage의 파생 token만 제거 — Antigravity의 Keychain 항목은 절대 수정하지 않음.
    func discardCachedToken() {
        do {
            try files.remove(Self.cachePath)
        } catch {
            AppLog.warn(LogTag.auth("antigravity"), "failed to remove stale refreshed-token cache")
        }
    }

    private static func credentialFingerprint(for refreshToken: String?) -> Data? {
        guard let refreshToken = refreshToken?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty else {
            return nil
        }
        return Data(SHA256.hash(data: Data(refreshToken.utf8)))
    }

    // MARK: - Token extraction (pure)

    /// keychain 값을 token으로 decode — `agy` 형식 미러링: JSON `{ token: { access_token, refresh_token, expiry }, … }`에 optional `go-keyring-base64:` wrapper, bare JSON string·`Bearer …`·raw token fallback.
    static func extractToken(fromKeychainRaw raw: String) -> AntigravityKeychainToken? {
        let boundaryCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\u{FEFF}"))
        let normalizedRaw = raw.trimmingCharacters(in: boundaryCharacters)
        guard let unwrapped = ProviderParse.unwrapGoKeyring(normalizedRaw),
              let text = unwrapped.trimmingCharacters(in: boundaryCharacters).nilIfEmpty
        else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            if let dict = json as? [String: Any] {
                return tokenFromObject(dict)
            }
            if let string = (json as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return AntigravityKeychainToken(accessToken: string, refreshToken: nil, expiry: nil)
            }
            return nil
        }

        // 손상된 구조화 데이터는 raw bearer token으로 전송 금지.
        if text.hasPrefix("{") || text.hasPrefix("[") {
            return nil
        }

        if text.hasPrefix("Bearer ") {
            let token = String(text.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            return token.map { AntigravityKeychainToken(accessToken: $0, refreshToken: nil, expiry: nil) }
        }
        return AntigravityKeychainToken(accessToken: text, refreshToken: nil, expiry: nil)
    }

    static func tokenFromObject(_ object: [String: Any]) -> AntigravityKeychainToken? {
        // 중첩 `token` 객체(agy 형태) 우선, 없으면 root에서 필드 읽기.
        let source = (object["token"] as? [String: Any]) ?? object
        let access = firstString(source, ["access_token", "accessToken", "token", "id_token", "idToken", "bearerToken", "auth_token", "authToken"])
        let refresh = firstString(source, ["refresh_token", "refreshToken"])
        let expiry = firstString(source, ["expiry", "expires_at", "expiresAt"]).flatMap { OpenUsageISO8601.date(from: $0) }

        if access == nil, refresh == nil {
            for key in ["tokens", "oauth", "oauth2", "credentials", "auth"] {
                if let nested = object[key] as? [String: Any], let token = tokenFromObject(nested) {
                    return token
                }
            }
            return nil
        }
        return AntigravityKeychainToken(accessToken: access, refreshToken: refresh, expiry: expiry)
    }

    private static func firstString(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                return value
            }
        }
        return nil
    }
}
