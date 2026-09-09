import Foundation
import XCTest
@testable import OpenUsage

final class URLSessionHTTPClientTests: XCTestCase {
    func testCookieFreeSessionRejectsRedirectsAndSharedCredentials() async throws {
        let session = URLSessionHTTPClient.makeCookieFreeSession()
        defer { session.invalidateAndCancel() }

        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)

        let delegate = try XCTUnwrap(session.delegate as? NoRedirectURLSessionDelegate)
        let sourceURL = try XCTUnwrap(URL(string: "https://codex-resets.com/api/v1/status"))
        let targets = [
            "http://127.0.0.1:6736/v1/usage",
            "http://[::1]:6736/v1/usage",
            "https://192.168.1.1/admin",
            "https://codex-resets.com/redirected"
        ]

        for rawTarget in targets {
            let targetURL = try XCTUnwrap(URL(string: rawTarget))
            let response = try XCTUnwrap(HTTPURLResponse(
                url: sourceURL,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": targetURL.absoluteString]
            ))
            let task = session.dataTask(with: sourceURL)

            let redirectedRequest: URLRequest? = await withCheckedContinuation { continuation in
                delegate.urlSession(
                    session,
                    task: task,
                    willPerformHTTPRedirection: response,
                    newRequest: URLRequest(url: targetURL)
                ) { request in
                    continuation.resume(returning: request)
                }
            }

            XCTAssertNil(redirectedRequest, rawTarget)
        }
    }

    func testCookieFreeSessionAllowsDirectResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuccessfulURLProtocol.self]
        let session = URLSessionHTTPClient.makeCookieFreeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "https://codex-resets.com/api/v1/status"))
        let (data, response) = try await session.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"data":{"active_watch":null}}"#)
    }
}

private final class SuccessfulURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Data(#"{"data":{"active_watch":null}}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
