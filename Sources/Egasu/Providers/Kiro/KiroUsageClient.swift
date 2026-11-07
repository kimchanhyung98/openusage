import Foundation

struct KiroUsageClient: Sendable {
    static let endpoint = URL(string: "https://codewhisperer.us-east-1.amazonaws.com/")!
    static let target = "AmazonCodeWhispererService.GetUsageLimits"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchUsageLimits(accessToken: String, profileArn: String) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: ["profileArn": profileArn])
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.endpoint,
            headers: [
                "Content-Type": "application/x-amz-json-1.0",
                "x-amz-target": Self.target,
                "Authorization": "Bearer \(accessToken)"
            ],
            body: body,
            timeout: 15
        ))
    }
}
