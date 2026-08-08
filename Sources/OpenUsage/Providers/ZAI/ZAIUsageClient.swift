import Foundation

struct ZAIUsageClient: Sendable {
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// 사용자의 활성 subscription 조회 — plan 이름 표시용 best-effort, 실패가 quota meter를 지우면 안 되므로 optional 취급.
    func fetchSubscription(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    /// session token 사용량과 web-search quota 조회 — 유효한 snapshot에 필수.
    func fetchQuota(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.quotaURL, apiKey: apiKey)
    }

    private func get(_ url: URL, apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum ZAIUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// key는 유효하나 계정에 GLM Coding Plan이 없는 상태 (quota endpoint가 2xx + `success:false` 응답).
    /// malformed·실패 요청과 구분 — meter할 대상 자체가 없음.
    case noCodingPlan

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noCodingPlan:
            return "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage."
        }
    }
}
