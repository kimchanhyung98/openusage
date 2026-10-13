import XCTest
@testable import OpenUsage

extension ClaudeDesktopAuthStoreTests {
    @MainActor
    func testLegacyDesktopLoginRecoversIdentityWithoutWritingCredentials() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let originalFiles = fixture.files.files
        let keychain = FakeKeychain()
        let organization = organization
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer desktop-token")
            let body = request.url.path.hasSuffix("/profile")
                ? #"{"account":{"uuid":"11111111-1111-4111-8111-111111111111"},"organization":{"uuid":"\#(organization)"}}"#
                : #"{"five_hour":{"utilization":42}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let now = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: fixture.files, keychain: keychain,
                                       desktop: fixture.store, now: { now }),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { now }, pricing: { TestPricing.bundled }
        )
        let result = await provider.refresh()

        XCTAssertEqual(result.line(label: "Session"), .progress(
            label: "Session", used: 42, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
        ))
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertEqual(fixture.files.files, originalFiles)
        XCTAssertNil(keychain.value)
    }

    @MainActor
    func testLegacyDesktopProfile401NeverExchangesRefreshToken() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let originalFiles = fixture.files.files
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let now = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: fixture.files, keychain: FakeKeychain(),
                                       desktop: fixture.store, now: { now }),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { now }, pricing: { TestPricing.bundled }
        )
        let result = await provider.refresh()

        XCTAssertEqual(badge(result.lines, "Error"), ClaudeAuthError.desktopTokenExpired.localizedDescription)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
        XCTAssertEqual(fixture.files.files, originalFiles)
    }
}
