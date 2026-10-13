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

    @MainActor
    func testLegacyDesktopFallbackMustMatchBoundHomeIdentity() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let otherAccount = "22222222-2222-4222-8222-222222222222"
        let cases: [(homeOrganization: String?, profileAccount: String, profileOrganization: String, allowed: Bool)] = [
            (organization, account, organization, true),
            (organization, otherAccount, organization, false),
            (organization, account, otherOrganization, false),
            (nil, account, organization, true),
            (nil, account, otherOrganization, true),
            (nil, otherAccount, organization, false)
        ]
        for testCase in cases {
            let fixture = try makeFixture(
                activeOrganization: testCase.profileOrganization,
                v2: [cacheKey(organization: testCase.profileOrganization): tokenEntry("desktop-token", expiresIn: 3_600)]
            )
            var homeIdentity = ["accountUuid": account]
            if let organization = testCase.homeOrganization { homeIdentity["organizationUuid"] = organization }
            fixture.files.files["/tmp/claude/.claude.json"] = String(
                decoding: try JSONSerialization.data(withJSONObject: ["oauthAccount": homeIdentity]), as: UTF8.self
            )
            let originalFiles = fixture.files.files
            let credentials = #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            let keychain = FakeKeychain(credentials)
            let http = RoutingHTTPClient { request in
                if request.headers["Authorization"] == "Bearer revoked-cli" {
                    XCTAssertEqual(request.url.path, "/api/oauth/usage")
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                XCTAssertEqual(request.headers["Authorization"], "Bearer desktop-token")
                let body = request.url.path.hasSuffix("/profile")
                    ? #"{"account":{"uuid":"\#(testCase.profileAccount)"},"organization":{"uuid":"\#(testCase.profileOrganization)"}}"#
                    : #"{"five_hour":{"utilization":42}}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            let now = now
            let provider = ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                    files: fixture.files, keychain: keychain, desktop: fixture.store, now: { now }
                ),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { now }, pricing: { TestPricing.bundled }
            )

            let result = await provider.refresh()

            if testCase.allowed {
                XCTAssertEqual(result.line(label: "Session"), .progress(
                    label: "Session", used: 42, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
                ))
                XCTAssertEqual(http.requests.map(\.url.path), [
                    "/api/oauth/usage", "/api/oauth/profile", "/api/oauth/usage"
                ])
            } else {
                XCTAssertEqual(badge(result.lines, "Error"), ClaudeUsageStateStore.StoreError.identityUnavailable.localizedDescription)
                XCTAssertNil(result.line(label: "Session"))
                XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/usage", "/api/oauth/profile"])
            }
            XCTAssertEqual(fixture.files.files, originalFiles)
            XCTAssertEqual(keychain.value, credentials)
        }
    }
}
