import Foundation

/// 커뮤니티 투표율은 같은 게시물의 집계로 계산하며, 조회 실패 시에도 AI 예측 유지.
enum CodexResetWatchVotes {
    struct Result: Sendable {
        var percent: Double?
        var retryNotBefore: Date?
    }

    static func episodeID(from source: String) -> String? {
        guard let url = URL(string: source), url.scheme == "https",
              ["x.com", "www.x.com", "twitter.com", "www.twitter.com"].contains(url.host) else { return nil }
        let parts = url.pathComponents
        guard parts.count == 4, parts[2] == "status", !parts[3].isEmpty,
              parts[3].allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return parts[3]
    }

    static func load(
        http: any HTTPClient,
        endpoint: URL,
        episodeID: String,
        now: @Sendable () -> Date = Date.init
    ) async -> Result {
        var request = HTTPRequest(method: "GET", url: endpoint, timeout: 4)
        request.headers = ["Accept": "application/json", "User-Agent": "OpenUsage", "Cache-Control": "no-cache"]
        var retryNotBefore: Date?
        do {
            let response = try await http.send(request)
            guard response.statusCode == 200 else {
                retryNotBefore = retryDeadline(response, now: now())
                throw VotesError.httpStatus(response.statusCode)
            }
            let votes = try JSONDecoder().decode(Payload.self, from: response.body)
            guard votes.episodeID == episodeID else { throw VotesError.episodeMismatch }
            let maximumSafeInteger: Int64 = 9_007_199_254_740_991
            guard (0...maximumSafeInteger).contains(votes.yes),
                  (0...maximumSafeInteger).contains(votes.no) else {
                throw VotesError.invalidCounts
            }
            guard votes.yes + votes.no > 0 else { throw VotesError.noVotes }
            AppDiagnostics.record(.resetVoteFetch, result: .success, providerID: "codex")
            return Result(percent: (Double(votes.yes) / (Double(votes.yes) + Double(votes.no)) * 100).rounded())
        } catch {
            AppDiagnostics.failure(.resetVoteFetch, error: error, providerID: "codex")
            return Result(retryNotBefore: retryNotBefore ?? now().addingTimeInterval(60))
        }
    }

    private static func retryDeadline(_ response: HTTPResponse, now: Date) -> Date {
        let fallback = now.addingTimeInterval(response.statusCode == 429 ? 300 : 60)
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return fallback }
        if let seconds = TimeInterval(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        guard let date = formatter.date(from: raw) else { return fallback }
        return max(now, date)
    }

    private struct Payload: Decodable {
        let episodeID: String
        let yes: Int64
        let no: Int64

        enum CodingKeys: String, CodingKey {
            case episodeID = "episode_id"
            case yes, no
        }
    }

    private enum VotesError: Error, LocalizedError, CategorizedError {
        var errorCategory: ErrorCategory {
            switch self {
            case .httpStatus(let code): .http(code)
            case .episodeMismatch, .invalidCounts: .decoding
            case .noVotes: .notAvailable
            }
        }

        case httpStatus(Int), episodeMismatch, invalidCounts, noVotes

        var errorDescription: String? {
            switch self {
            case .httpStatus(let status): "HTTP \(status)"
            case .episodeMismatch: "Vote episode did not match the active forecast"
            case .invalidCounts: "Vote counts were invalid"
            case .noVotes: "No votes yet"
            }
        }
    }
}
