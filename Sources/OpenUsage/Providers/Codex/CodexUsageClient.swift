import Foundation

struct CodexRefreshResponse: Sendable, Equatable {
    var accessToken: String
    var refreshToken: String?
    var idToken: String?
}

struct CodexUsageClient: Sendable {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let refreshURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    static let consumeResetCreditURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func refreshToken(_ refreshToken: String) async throws -> CodexRefreshResponse {
        let body =
            "grant_type=refresh_token" +
            "&client_id=\(Self.clientID.urlFormEncoded)" +
            "&refresh_token=\(refreshToken.urlFormEncoded)"

        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))

        if response.statusCode == 400 || response.statusCode == 401 {
            let errorBody = ProviderParse.jsonObject(response.body)
            let code = errorBody?["error"].flatMap { errorValue -> String? in
                if let error = errorValue as? [String: Any] {
                    return error["code"] as? String ?? error["error"] as? String
                }
                return errorValue as? String
            } ?? errorBody?["code"] as? String

            switch code {
            case "refresh_token_expired":
                throw CodexAuthError.sessionExpired
            case "refresh_token_reused":
                throw CodexAuthError.tokenConflict
            case "refresh_token_invalidated":
                throw CodexAuthError.tokenRevoked
            default:
                // 인식된 OAuth error code 없음(대개 비-JSON proxy/WAF page) — 재로그인으로 못 고치는 token 만료 단정 대신 HTTP status 보고.
                throw CodexUsageError.requestFailed(response.statusCode)
            }
        }

        // 400/401 외 non-2xx(5xx, gateway 오류)는 token 만료가 아닌 request 실패 — status 노출.
        // usable access token 없는 2xx body는 dead session 취급 — 재로그인이 올바른 해법.
        guard (200..<300).contains(response.statusCode) else {
            throw CodexUsageError.requestFailed(response.statusCode)
        }
        guard let body = ProviderParse.jsonObject(response.body),
              let accessToken = body["access_token"] as? String,
              !accessToken.isEmpty
        else {
            throw CodexAuthError.tokenExpired
        }

        return CodexRefreshResponse(
            accessToken: accessToken,
            refreshToken: body["refresh_token"] as? String,
            idToken: body["id_token"] as? String
        )
    }

    func fetchUsage(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OpenUsage"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: headers,
            timeout: 10
        ))
    }

    /// On-demand rate-limit reset credit 목록 조회 — per-credit expiry 포함 (usage body의 `rate_limit_reset_credits`는 count만 제공하는 별개 필드).
    /// 추가 header는 endpoint가 기대하는 Codex desktop client mirror. Best-effort — 실패 시 provider가 usage body의 count로 fallback.
    func fetchResetCredits(accessToken: String, accountID: String?) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "User-Agent": "OpenUsage",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: Self.resetCreditsURL,
            headers: headers,
            timeout: 10
        ))
    }

    /// Rate-limit reset credit 1개 consume — Codex CLI와 실계정에서 검증한 계약.
    /// `redeemRequestID`는 caller의 idempotency key (credit당 UUID 1회 발급·retry 재사용 — 재시도가 두 번째 credit을 소모 불가, 서버는 `already_redeemed` 응답); `creditID`로 정확히 1개 지정 — 서버 선택 금지.
    /// Outcome은 200 body의 `code` (reset / already_redeemed / nothing_to_reset / no_credit) — `CodexResetClaimService.outcome(fromConsume:)` 참고.
    func consumeResetCredit(
        accessToken: String,
        accountID: String?,
        creditID: String,
        redeemRequestID: String
    ) async throws -> HTTPResponse {
        var headers = [
            "Authorization": "Bearer \(accessToken)",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "OpenUsage",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let payload = ["redeem_request_id": redeemRequestID, "credit_id": creditID]
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.consumeResetCreditURL,
            headers: headers,
            body: body,
            timeout: 15
        ))
    }

}
