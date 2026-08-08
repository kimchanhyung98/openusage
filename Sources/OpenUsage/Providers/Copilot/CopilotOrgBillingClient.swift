import Foundation

/// GitHub 공개 REST billing endpoint로 org 관리 Copilot seat의 organization을 찾고 월누적 usage 읽기. `/copilot_internal/user`가 per-seat quota 없는 token-based-billing seat(org 관리 Copilot Business/Enterprise)를 보고할 때만 사용 — usage는 organization billing에만 존재.
/// org billing 읽기는 org owner/billing manager 권한 필요 — 일반 member는 403. 이는 오류가 아닌 기대 상태로 provider가 처리.
struct CopilotOrgBillingClient: Sendable {
    static let userOrgsURL = "https://api.github.com/user/orgs?per_page=100"

    static func usageSummaryURL(org: String) -> URL? {
        // org slug는 영숫자+하이픈이지만 경로 삽입 전 방어적으로 encode.
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://api.github.com/orgs/\(encoded)/settings/billing/usage/summary")
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// token 사용자가 속한 organization (첫 페이지, 최대 100 — 용도상 충분).
    func fetchUserOrgs(token: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.userOrgsURL) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    /// organization 하나의 월누적 billing usage summary.
    func fetchUsageSummary(org: String, token: String) async throws -> HTTPResponse {
        guard let url = Self.usageSummaryURL(org: org) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    private func send(url: URL, token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/vnd.github+json",
                "User-Agent": "OpenUsage",
                "X-GitHub-Api-Version": "2022-11-28"
            ],
            timeout: 15
        ))
    }
}
