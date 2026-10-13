import XCTest
@testable import OpenUsage

@MainActor
final class GrokRefreshSafetyTests: XCTestCase {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let entryKey = "https://auth.x.ai::client"
    private nonisolated static let original = #"{"https://auth.x.ai::client":{"key":"token-A","refresh_token":"refresh-A","expires_at":"2020-01-01T00:00:00Z","custom":"keep"}}"#
    private nonisolated static let replacement = #"{"https://auth.x.ai::client":{"key":"token-B","refresh_token":"refresh-B","expires_at":"2099-01-01T00:00:00Z"}}"#

    func testDelayedRefreshPreservesReloginAndLogout() async {
        for replacement in [Self.replacement, nil, "{}",
                            Self.original.replacingOccurrences(of: "refresh-A", with: "externally-rotated"),
                            Self.original.replacingOccurrences(of: "keep", with: "changed")] as [String?] {
            let files = FakeFiles([GrokAuthStore.authPath: Self.original])
            let http = GrokSafetyHTTP { request in
                if request.url == GrokUsageClient.refreshURL {
                    files.files[GrokAuthStore.authPath] = replacement
                    return Self.rotationResponse
                }
                return Self.usageResponse
            }

            let snapshot = await makeProvider(files: files, http: http).refresh()

            XCTAssertEqual(files.files[GrokAuthStore.authPath], replacement)
            XCTAssertNotNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.authenticationIssue)
            XCTAssertEqual(http.requests.map(\.url), [GrokUsageClient.refreshURL])
        }
    }

    func testPersistenceFailureKeepsOriginalSignInAndUsesRotatedTokenForUsage() async {
        for expiryYear in ["2020", "2099"] {
            let original = Self.original.replacingOccurrences(of: "2020", with: expiryYear)
            let files = GrokWriteFailingFiles([GrokAuthStore.authPath: original])
            let http = GrokSafetyHTTP { request in
                if request.url == GrokUsageClient.refreshURL { return Self.rotationResponse }
                if request.url == GrokUsageClient.creditsConfigURL {
                    guard request.headers["Authorization"] == "Bearer rotated-A" else {
                        return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                    }
                    return Self.usageResponse
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }

            let snapshot = await makeProvider(files: files, http: http).refresh()

            XCTAssertNil(snapshot.errorCategory, expiryYear)
            XCTAssertNil(snapshot.authenticationIssue, expiryYear)
            XCTAssertEqual(files.backing.files[GrokAuthStore.authPath], original, expiryYear)
            XCTAssertEqual(files.writeAttempts, 1, expiryYear)
            XCTAssertEqual(http.requests.filter { $0.url == GrokUsageClient.refreshURL }.count, 1, expiryYear)
            let usageAuthorizations = http.requests
                .filter { $0.url == GrokUsageClient.creditsConfigURL }
                .map { $0.headers["Authorization"] }
            XCTAssertEqual(
                usageAuthorizations,
                expiryYear == "2020" ? ["Bearer rotated-A"] : ["Bearer token-A", "Bearer rotated-A"],
                expiryYear
            )
            XCTAssertEqual(
                http.requests.first { $0.url == GrokUsageClient.settingsURL }?.headers["Authorization"],
                "Bearer rotated-A", expiryYear
            )
        }
    }

    func testConcurrentSiblingChangesAreKeptWhenTheSelectedEntryIsUnchanged() async throws {
        let files = FakeFiles([GrokAuthStore.authPath: Self.original])
        let http = GrokSafetyHTTP { request in
            if request.url == GrokUsageClient.refreshURL {
                var object = try XCTUnwrap(GrokAuthStore.parseJSONObject(Self.original))
                object["sibling"] = ["key": "sibling-new-login", "nested": ["keep": true]] as [String: Any]
                files.files[GrokAuthStore.authPath] = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                return Self.rotationResponse
            }
            return Self.usageResponse
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        let object = try XCTUnwrap(GrokAuthStore.parseJSONObject(try XCTUnwrap(files.files[GrokAuthStore.authPath])))
        let sibling = try XCTUnwrap(object["sibling"] as? [String: Any])
        XCTAssertEqual(sibling["key"] as? String, "sibling-new-login")
        XCTAssertEqual(sibling["nested"] as? [String: Bool], ["keep": true])
        let selected = try XCTUnwrap(object[Self.entryKey] as? [String: Any])
        XCTAssertEqual(selected["custom"] as? String, "keep")
        XCTAssertEqual(selected["key"] as? String, "rotated-A")
    }

    func testProactiveRotationFollowedByUnauthorizedRetryUsesTheSavedGeneration() async throws {
        let files = FakeFiles([GrokAuthStore.authPath: Self.original])
        let http = GrokSafetyHTTP { request in
            if request.url == GrokUsageClient.refreshURL {
                if String(decoding: request.body ?? Data(), as: UTF8.self).contains("rotated-refresh-A") {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"access_token":"second-rotation","refresh_token":"second-refresh","expires_in":3600}"#.utf8
                    ))
                }
                return Self.rotationResponse
            }
            if request.url == GrokUsageClient.creditsConfigURL,
               request.headers["Authorization"] == "Bearer rotated-A" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Self.usageResponse
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.filter { $0.url == GrokUsageClient.refreshURL }.count, 2)
        XCTAssertEqual(GrokAuthStore.parseAuth(try XCTUnwrap(files.files[GrokAuthStore.authPath]))?[Self.entryKey]?.key,
                       "second-rotation")
    }

    private func makeProvider(files: TextFileAccessing, http: HTTPClient) -> GrokProvider {
        GrokProvider(
            authStore: GrokAuthStore(files: files, now: { Self.now }),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(),
                                                homeDirectory: { URL(fileURLWithPath: "/fixture") }),
            now: { Self.now }, pricing: { .empty }
        )
    }

    private nonisolated static var rotationResponse: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"access_token":"rotated-A","refresh_token":"rotated-refresh-A","expires_in":3600}"#.utf8
        ))
    }

    private nonisolated static var usageResponse: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
    }
}

private final class GrokSafetyHTTP: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    let handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private final class GrokWriteFailingFiles: TextFileAccessing, @unchecked Sendable {
    let backing: FakeFiles
    private(set) var writeAttempts = 0

    init(_ files: [String: String]) { backing = FakeFiles(files) }

    func exists(_ path: String) -> Bool { backing.exists(path) }
    func readText(_ path: String) throws -> String { try backing.readText(path) }
    func remove(_ path: String) throws { try backing.remove(path) }

    func writeText(_ path: String, _ text: String) throws {
        writeAttempts += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}
