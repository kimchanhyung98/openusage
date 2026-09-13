import Foundation

extension ClaudeDesktopAuthStore {
    private static let apiHost = "https://api.anthropic.com"
    private static let usageScope = "user:profile"
    private static let expirySafetyMarginMs = 2 * 60 * 1000.0

    enum Selection: Sendable {
        case available(ClaudeOAuth)
        case stale
        case notFound
        case invalid
    }

    static func selectCredential(
        activeOrganization: String,
        activeAccountUUID: String? = nil,
        v2: [String: Any]?,
        v1: [String: Any]?,
        now: Date
    ) -> Selection {
        let normalizedOrg = activeOrganization.lowercased()
        let v2Entries = normalizedCache(v2, activeAccountUUID: activeAccountUUID)
        let v1Entries = normalizedCache(v1, activeAccountUUID: activeAccountUUID)
        let v2Candidates = candidates(in: v2Entries, organization: normalizedOrg, now: now)
        if let best = v2Candidates.available.max(by: { $0.rank < $1.rank }) {
            return .available(best.oauth)
        }

        let v1Candidates = candidates(
            in: v1Entries.filter { v2Entries[$0.key] == nil },
            organization: normalizedOrg,
            now: now
        )
        if let best = v1Candidates.available.max(by: { $0.rank < $1.rank }) {
            return .available(best.oauth)
        }
        if v2Candidates.sawStale || v1Candidates.sawStale { return .stale }
        if v2Candidates.sawInvalid || v1Candidates.sawInvalid { return .invalid }
        return .notFound
    }

    /// Claude 프로덕션 로그인(Code/Desktop)이 full-scope 토큰을 발급받는 OAuth client ID —
    /// Desktop 자신이 활성 로그인을 판별하는 기준.
    private static let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let inferenceScope = "user:inference"

    private struct Candidate {
        var oauth: ClaudeOAuth
        var clientID: String
        var scopes: [String]
        var expiresAt: Double

        /// Desktop 자체 해석과 동일한 선택 순서 — 프로덕션 client + full scope 우선, 만료는 최종 tiebreak.
        /// TTL 긴 stale 토큰이 현재 로그인을 앞서면 안 됨.
        var rank: (Int, Int, Int, Double) {
            let hasFullScope = scopes.contains(ClaudeDesktopAuthStore.usageScope)
                && scopes.contains(ClaudeDesktopAuthStore.inferenceScope)
            let isProductionClient = clientID == ClaudeDesktopAuthStore.productionClientID
            return (
                isProductionClient && hasFullScope ? 1 : 0,
                hasFullScope ? 1 : 0,
                scopes.count,
                expiresAt
            )
        }
    }

    private static func candidates(
        in cache: [CacheKey: Any],
        organization: String,
        now: Date
    ) -> (available: [Candidate], sawStale: Bool, sawInvalid: Bool) {
        var available: [Candidate] = []
        var sawStale = false
        var sawInvalid = false
        for (parsedKey, rawEntry) in cache {
            guard parsedKey.organization == organization,
                  parsedKey.apiHost == apiHost,
                  parsedKey.scopes.contains(usageScope)
            else {
                continue
            }
            guard !(rawEntry is NSNull) else { continue }
            guard let entry = rawEntry as? [String: Any],
                  let token = entry["token"] as? String,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let expiresAt = number(entry["expiresAt"]),
                  expiresAt.isFinite
            else {
                sawInvalid = true
                continue
            }
            guard expiresAt > now.timeIntervalSince1970 * 1000 + expirySafetyMarginMs else {
                sawStale = true
                continue
            }
            let oauth = ClaudeOAuth(
                accessToken: token,
                refreshToken: nil,
                expiresAt: expiresAt,
                subscriptionType: entry["subscriptionType"] as? String,
                rateLimitTier: entry["rateLimitTier"] as? String,
                scopes: parsedKey.scopes
            )
            available.append(Candidate(
                oauth: oauth,
                clientID: parsedKey.clientID,
                scopes: parsedKey.scopes,
                expiresAt: expiresAt
            ))
        }
        return (available, sawStale, sawInvalid)
    }

    private struct CacheKey: Hashable {
        var clientID: String
        var organization: String
        var apiHost: String
        var scopes: [String]
    }

    /// 현재 계정의 scoped 항목은 삭제 마커까지 legacy alias보다 우선. 다른 계정은 V1 대체 경로도 억제하지 않음.
    private static func normalizedCache(
        _ cache: [String: Any]?, activeAccountUUID: String?
    ) -> [CacheKey: Any] {
        guard let cache else { return [:] }
        let activeAccount = activeAccountUUID.flatMap(UUID.init(uuidString:))
        var legacy: [CacheKey: Any] = [:]
        var scoped: [CacheKey: Any] = [:]
        for (rawKey, entry) in cache.sorted(by: { $0.key < $1.key }) {
            let isScoped = rawKey.hasPrefix("acct:")
            var key = rawKey
            if isScoped {
                let parts = rawKey.dropFirst(5).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let owner = UUID(uuidString: String(parts[0])),
                      let activeAccount, owner == activeAccount
                else { continue }
                key = String(parts[1])
            }
            guard let parsed = parseCacheKey(key) else { continue }
            if isScoped {
                scoped[parsed] = scoped[parsed].map { preferred($0, over: entry) } ?? entry
            } else {
                legacy[parsed] = legacy[parsed].map { preferred($0, over: entry) } ?? entry
            }
        }
        return legacy.merging(scoped) { _, scopedEntry in scopedEntry }
    }

    /// 같은 cache 버전에서 하나의 key로 접히는 scope alias 충돌 해소.
    /// 삭제 마커가 항상 우선 — 지워진 토큰이 다른 철자의 alias로 되살아나지 않음.
    /// 남은 경우는 만료가 늦은 항목 채택 — raw key 문자열 정렬이 결과를 정하지 않도록 명시적 규칙 유지.
    private static func preferred(_ existing: Any, over candidate: Any) -> Any {
        guard !(existing is NSNull), !(candidate is NSNull) else { return NSNull() }
        let existingExpiry = (existing as? [String: Any]).flatMap { number($0["expiresAt"]) } ?? -.infinity
        let candidateExpiry = (candidate as? [String: Any]).flatMap { number($0["expiresAt"]) } ?? -.infinity
        return candidateExpiry > existingExpiry ? candidate : existing
    }

    private static func parseCacheKey(_ value: String) -> CacheKey? {
        let marker = ":\(apiHost):"
        guard let markerRange = value.range(of: marker) else { return nil }
        let prefix = value[..<markerRange.lowerBound]
        guard let firstColon = prefix.firstIndex(of: ":") else { return nil }
        let clientID = String(prefix[..<firstColon]).lowercased()
        let organization = String(prefix[prefix.index(after: firstColon)...]).lowercased()
        guard UUID(uuidString: clientID) != nil, UUID(uuidString: organization) != nil else {
            return nil
        }
        let scopes = Set(value[markerRange.upperBound...]
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)).sorted()
        return CacheKey(clientID: clientID, organization: organization, apiHost: apiHost, scopes: scopes)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
