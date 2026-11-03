import Foundation

struct OpenRouterUsageClient: Sendable {
    static let creditsURL = "https://openrouter.ai/api/v1/credits"
    static let keyURL = "https://openrouter.ai/api/v1/key"
    static let analyticsURL = "https://openrouter.ai/api/v1/analytics/query"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// 계정 전체 credit balance와 누적 spend 조회 — key 타입별 endpoint gate 가능성 때문에 key metadata와 독립 fetch.
    func fetchCredits(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.creditsURL, apiKey: apiKey)
    }

    /// best-effort key metadata 조회 — tier, per-key spend cap(선택), daily/weekly/monthly spend.
    func fetchKey(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.keyURL, apiKey: apiKey)
    }

    func fetchAnalytics(apiKey: String, start: Date, end: Date) async throws -> HTTPResponse {
        guard let url = URL(string: Self.analyticsURL) else {
            throw OpenRouterUsageError.invalidResponse
        }
        let body: [String: Any] = [
            "metrics": ["total_usage", "tokens_total"],
            "time_range": [
                "start": OpenUsageISO8601.string(from: start),
                "end": OpenUsageISO8601.string(from: end)
            ],
            "limit": 10
        ]

        return try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "Content-Type": "application/json"
            ],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }

    private func get(_ urlString: String, apiKey: String) async throws -> HTTPResponse {
        guard let url = URL(string: urlString) else {
            throw OpenRouterUsageError.invalidResponse
        }

        return try await http.send(HTTPRequest(
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

enum OpenRouterUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Couldn't reach OpenRouter. Check your connection."
        case .invalidResponse:
            return "OpenRouter usage data unavailable. Try again later."
        case .requestFailed(let status):
            return "OpenRouter request failed (HTTP \(status))."
        }
    }
}
