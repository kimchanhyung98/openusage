import XCTest
@testable import OpenUsage

final class KiroUsageClientTests: XCTestCase {
    func testBuildsVerifiedUsageRequest() async throws {
        let http = KiroUsageHTTPFake { request in
            HTTPResponse(statusCode: 200, headers: ["x-test": "ok"], body: Data(#"{"ok":true}"#.utf8))
        }
        let client = KiroUsageClient(http: http)

        let response = try await client.fetchUsageLimits(
            accessToken: "access-token",
            profileArn: "arn:aws:codewhisperer:us-east-1:123456789012:profile/ABC"
        )

        XCTAssertEqual(response.statusCode, 200)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, KiroUsageClient.endpoint)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-amz-json-1.0")
        XCTAssertEqual(request.headers["x-amz-target"], KiroUsageClient.target)
        XCTAssertEqual(request.headers["Authorization"], "Bearer access-token")
        XCTAssertEqual(request.timeout, 15)
        let body = try XCTUnwrap(request.body)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, [
            "profileArn": "arn:aws:codewhisperer:us-east-1:123456789012:profile/ABC"
        ])
    }

    func testPassesThroughSuccessAndNonSuccessResponses() async throws {
        for status in [200, 204, 400, 401, 403, 429, 500] {
            let expectedBody = Data("status-\(status)".utf8)
            let http = KiroUsageHTTPFake { _ in
                HTTPResponse(statusCode: status, headers: ["x-status": "\(status)"], body: expectedBody)
            }

            let response = try await KiroUsageClient(http: http).fetchUsageLimits(
                accessToken: "token",
                profileArn: "arn:profile"
            )

            XCTAssertEqual(response.statusCode, status)
            XCTAssertEqual(response.headers["x-status"], "\(status)")
            XCTAssertEqual(response.body, expectedBody)
        }
    }

    func testPropagatesNetworkFailure() async {
        let http = KiroUsageHTTPFake { _ in throw URLError(.cannotConnectToHost) }

        do {
            _ = try await KiroUsageClient(http: http).fetchUsageLimits(
                accessToken: "secret-token",
                profileArn: "arn:secret-profile"
            )
            XCTFail("expected network failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
            XCTAssertFalse(error.localizedDescription.contains("secret-token"))
            XCTAssertFalse(error.localizedDescription.contains("arn:secret-profile"))
        }
    }

    func testUsesBoundedTimeout() async {
        let http = KiroUsageHTTPFake { request in
            XCTAssertEqual(request.timeout, 15)
            throw URLError(.timedOut)
        }

        do {
            _ = try await KiroUsageClient(http: http).fetchUsageLimits(
                accessToken: "token",
                profileArn: "arn:profile"
            )
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }
}

private final class KiroUsageHTTPFake: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse

    init(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try await handler(request)
    }
}
