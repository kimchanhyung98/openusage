import Foundation

struct KimiUsageClient: Sendable {
    static let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    static let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    static let refreshURL = URL(string: "https://auth.kimi.com/api/oauth/token")!

    var http: any HTTPClient
    var now: @Sendable () -> Date

    init(
        http: any HTTPClient = URLSessionHTTPClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.now = now
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: Self.usageURL,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }

    func refreshToken(refreshToken: String) async throws -> KimiTokenRefresh {
        let body = [
            "client_id=\(Self.clientID.urlFormEncoded)",
            "grant_type=refresh_token",
            "refresh_token=\(refreshToken.urlFormEncoded)"
        ].joined(separator: "&")
        let response = try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8),
            timeout: 15
        ))

        if response.statusCode == 401 || response.statusCode == 403 {
            throw KimiAuthError.refreshRejected
        }
        if response.statusCode == 400,
           (ProviderParse.jsonObject(response.body)?["error"] as? String) == "invalid_grant" {
            throw KimiAuthError.refreshRejected
        }
        guard (200..<300).contains(response.statusCode) else {
            throw KimiUsageError.requestFailed(response.statusCode)
        }
        guard let object = ProviderParse.jsonObject(response.body),
              let accessToken = Self.string(object["access_token"]),
              let rotatedRefreshToken = Self.string(object["refresh_token"]),
              let expiresIn = ProviderParse.number(object["expires_in"]),
              expiresIn > 0
        else {
            throw KimiAuthError.refreshResponseInvalid
        }

        return KimiTokenRefresh(
            accessToken: accessToken,
            refreshToken: rotatedRefreshToken,
            expiresAt: now().addingTimeInterval(expiresIn),
            expiresIn: expiresIn,
            scope: Self.string(object["scope"]),
            tokenType: Self.string(object["token_type"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
