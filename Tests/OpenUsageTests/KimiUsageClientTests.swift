import Foundation
import XCTest
@testable import OpenUsage

final class KimiUsageClientTests: XCTestCase {
    func testFetchUsageBuildsCLICompatibleRequest() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 429, headers: [:], body: Data("limited".utf8))
        }
        let client = KimiUsageClient(http: http)

        let response = try await client.fetchUsage(accessToken: "fake-access-token")

        XCTAssertEqual(response.statusCode, 429)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, KimiUsageClient.usageURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer fake-access-token")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertNil(request.body)
        XCTAssertEqual(request.timeout, 15)
    }

    func testRefreshTokenFormEncodesReservedCharactersAndMapsResponse() async throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let http = RoutingHTTPClient { _ in
            HTTPResponse(
                statusCode: 200,
                headers: [:],
                body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":"3600","scope":"openid profile","token_type":"Bearer"}"#.utf8)
            )
        }
        let client = KimiUsageClient(http: http, now: { now })

        let token = try await client.refreshToken(refreshToken: "refresh token&=+/?%")

        XCTAssertEqual(token.accessToken, "new-access")
        XCTAssertEqual(token.refreshToken, "new-refresh")
        XCTAssertEqual(token.expiresIn, 3_600)
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3_600))
        XCTAssertEqual(token.scope, "openid profile")
        XCTAssertEqual(token.tokenType, "Bearer")

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, KimiUsageClient.refreshURL)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            "client_id=17e5f671-d194-4dfb-9706-5516cb48c098" +
                "&grant_type=refresh_token" +
                "&refresh_token=refresh%20token%26%3D%2B%2F%3F%25"
        )
        XCTAssertEqual(request.timeout, 15)
    }

    func testInvalidGrantAndAuthStatusesReturnRefreshRejected() async {
        let cases: [(Int, String)] = [
            (400, #"{"error":"invalid_grant"}"#),
            (401, ""),
            (403, "")
        ]

        for (status, body) in cases {
            let client = KimiUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
            })

            do {
                _ = try await client.refreshToken(refreshToken: "fake-refresh-token")
                XCTFail("expected refresh rejection for HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? KimiAuthError, .refreshRejected)
            }
        }
    }

    func testNonAuthRefreshFailuresPreserveHTTPStatus() async {
        for status in [400, 429, 503] {
            let client = KimiUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: status, headers: [:], body: Data(#"{"error":"server_error"}"#.utf8))
            })

            do {
                _ = try await client.refreshToken(refreshToken: "fake-refresh-token")
                XCTFail("expected request failure for HTTP \(status)")
            } catch {
                XCTAssertEqual(error as? KimiUsageError, .requestFailed(status))
            }
        }
    }

    func testMalformedOrIncompleteRefreshResponseIsRejected() async {
        let bodies = [
            "not-json",
            #"{"access_token":"new","refresh_token":"rotated"}"#,
            #"{"access_token":"new","refresh_token":"","expires_in":3600}"#,
            #"{"access_token":"new","refresh_token":"rotated","expires_in":0}"#,
            #"{"access_token":"","refresh_token":"rotated","expires_in":3600}"#
        ]

        for body in bodies {
            let client = KimiUsageClient(http: RoutingHTTPClient { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            })

            do {
                _ = try await client.refreshToken(refreshToken: "fake-refresh-token")
                XCTFail("expected an invalid refresh response")
            } catch {
                XCTAssertEqual(error as? KimiAuthError, .refreshResponseInvalid)
            }
        }
    }

    func testTransportErrorsPropagateFromClientBoundary() async {
        let client = KimiUsageClient(http: RoutingHTTPClient { _ in
            throw KimiClientTestError.offline
        })

        do {
            _ = try await client.fetchUsage(accessToken: "fake-access-token")
            XCTFail("expected fetch transport error")
        } catch {
            XCTAssertEqual(error as? KimiClientTestError, .offline)
        }

        do {
            _ = try await client.refreshToken(refreshToken: "fake-refresh-token")
            XCTFail("expected refresh transport error")
        } catch {
            XCTAssertEqual(error as? KimiClientTestError, .offline)
        }
    }

    func testErrorsNeverEchoCredentialValues() async {
        let secret = "fake-secret-refresh-token"
        let client = KimiUsageClient(http: RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        })

        do {
            _ = try await client.refreshToken(refreshToken: secret)
            XCTFail("expected refresh rejection")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }
}

private enum KimiClientTestError: Error, Equatable {
    case offline
}
