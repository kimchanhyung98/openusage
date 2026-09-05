import Foundation
import XCTest
@testable import OpenUsage

final class ProviderStatusHTTPClientTests: XCTestCase {
    func testConfigurationDoesNotPersistWebStateAndBoundsRequests() {
        let configuration = ProviderStatusHTTPClient.configuration(proxy: nil)

        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 10)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 10)
    }

    func testConfigurationAppliesTheExplicitProxy() {
        let proxy = ProxyConfig(
            scheme: .https,
            host: "proxy.example.com",
            port: 8443,
            username: nil,
            password: nil
        )

        let configuration = ProviderStatusHTTPClient.configuration(proxy: proxy)

        XCTAssertEqual(configuration.proxyConfigurations.count, 1)
    }

    func testBuildsCredentialFreeHTTPSGETRequest() throws {
        let input = HTTPRequest(
            method: "GET",
            url: try XCTUnwrap(URL(string: "https://status.example.com/api/v2/components.json"))
        )

        let request = try ProviderStatusHTTPClient.urlRequest(from: input)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 10)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testRejectsRequestsOutsideTheStatusTransportBoundary() throws {
        let url = try XCTUnwrap(URL(string: "https://status.example.com/components.json"))
        let invalidRequests = [
            HTTPRequest(method: "POST", url: url),
            HTTPRequest(method: "GET", url: url, body: Data()),
            HTTPRequest(method: "GET", url: try XCTUnwrap(URL(string: "http://status.example.com"))),
            HTTPRequest(method: "GET", url: try XCTUnwrap(URL(string: "https://user:secret@status.example.com"))),
            HTTPRequest(method: "GET", url: url, headers: ["Authorization": "Bearer secret"]),
        ]

        for request in invalidRequests {
            XCTAssertThrowsError(try ProviderStatusHTTPClient.urlRequest(from: request)) { error in
                XCTAssertEqual(error as? ProviderStatusHTTPClientError, .invalidRequest)
            }
        }
    }

    func testRedirectDelegateKeepsTheOriginalResponse() throws {
        let originalURL = try XCTUnwrap(URL(string: "https://status.example.com/components.json"))
        let redirectURL = try XCTUnwrap(URL(string: "https://redirect.example.com/components.json"))
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": redirectURL.absoluteString]
        ))
        var followedRequest: URLRequest? = URLRequest(url: redirectURL)

        ProviderStatusRedirectDelegate().urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectURL)
        ) { followedRequest = $0 }

        XCTAssertNil(followedRequest)
        session.invalidateAndCancel()
    }

    func testResponsePreservesStatusAndBodyWhileNormalizingHeaderNames() throws {
        let url = try XCTUnwrap(URL(string: "https://status.example.com/components.json"))
        let body = Data("rate limited".utf8)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Retry-After": "120"]
        ))

        let result = try ProviderStatusHTTPClient.response(from: response, data: body)

        XCTAssertEqual(result.statusCode, 429)
        XCTAssertEqual(result.header("content-type"), "application/json")
        XCTAssertEqual(result.header("retry-after"), "120")
        XCTAssertEqual(result.body, body)
        XCTAssertTrue(result.headers.keys.allSatisfy { $0 == $0.lowercased() })
    }
}
