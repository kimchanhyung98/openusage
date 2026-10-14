import os
import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeIdentityRecoveryEdgeTests: XCTestCase {
    private let path = "/tmp/claude/.credentials.json"
    private let metadataPath = "/tmp/claude/.claude.json"
    private let accountOnlyMetadata = #"{"oauthAccount":{"accountUuid":"account-a"}}"#

    func testManagedSnapshotWithoutVerifiedIdentityDoesNotRecoverAnotherAccount() async throws {
        for metadata in [nil, "invalid-json", "{}", #"{"accountUuid":""}"#] as [String?] {
            let keychain = ServiceKeychain()
            let profile = AccountProfile(
                id: "saved-account", family: "claude", label: "Saved Account",
                identityKey: "account-a|test-org", createdAt: .distantPast
            )
            let vault = AccountCredentialVault(keychain: keychain)
            let entry = AccountCredentialVault.Entry(credential: credentials(), claudeOAuthAccount: metadata)
            try vault.save(entry, profile: profile)
            let http = RoutingHTTPClient { request in
                request.url.path.hasSuffix("/profile") ? Self.profile(account: "account-b") : Self.usage()
            }
            let runtime = ClaudeProvider(
                provider: ClaudeProvider.makeProvider(id: "claude@profile-saved-account"),
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                    scope: .accountSnapshot(profileID: profile.id)
                ),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includePiUsage: false,
                pricing: { TestPricing.bundled }
            )

            let result = await runtime.refresh()

            XCTAssertFalse(result.lines.isEmpty)
            XCTAssertTrue(result.lines.allSatisfy(\.isError))
            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(try vault.load(profile: profile), entry)
        }
    }

    func testAccountOnlyFileFallbackPreservesCooldownAndLastGood() async {
        let store = isolatedClaudeUsageStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let files = FakeFiles([path: credentials(), metadataPath: accountOnlyMetadata])
        let keychain = staleKeychain(files: files)
        let usageCount = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer stale" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url.path.hasSuffix("/profile") { return Self.profile(account: "ACCOUNT-A") }
            let count = usageCount.withLock { $0 += 1; return $0 }
            return count == 1 ? Self.usage() : HTTPResponse(statusCode: 429, headers: [:], body: Data())
        }
        func makeProvider() -> ClaudeProvider {
            provider(files: files, http: http, keychain: keychain, store: store, now: { clock.withLock { $0 } })
        }
        let first = await makeProvider().refresh()
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await makeProvider().refresh()
        let requestsBeforeRestart = http.requests.count
        clock.withLock { $0 = start.addingTimeInterval(2) }
        let restarted = await makeProvider().refresh()

        XCTAssertEqual(first.line(label: "Session"), Self.session)
        XCTAssertEqual(limited.usageRetryAfter, start.addingTimeInterval(901))
        XCTAssertEqual(restarted.usageRetryAfter, limited.usageRetryAfter)
        XCTAssertEqual(restarted.quotaObservedAt, start)
        XCTAssertEqual(restarted.line(label: "Session"), Self.session)
        XCTAssertNil(restarted.liveQuotaObservedAt)
        XCTAssertEqual(usageCount.withLock { $0 }, 2)
        XCTAssertEqual(Array(http.requests.dropFirst(requestsBeforeRestart)).map(\.url.path), [
            "/api/oauth/profile", "/api/oauth/profile"
        ])
    }

    func testAccountOnlyFileFallbackRejectsAnotherAccount() async {
        await assertRejectedFallback(
            metadata: accountOnlyMetadata, profile: Self.profile(account: "account-b"),
            primaryRequestPath: "/api/oauth/profile"
        )
    }

    func testAccountOnlyFileFallbackKeepsOrganizationsInSeparateUsageRecords() async {
        let store = isolatedClaudeUsageStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let files = FakeFiles([path: credentials(), metadataPath: accountOnlyMetadata])
        let keychain = staleKeychain(files: files)
        let originalUsageCount = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"]
            if authorization == "Bearer stale" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            let isAnotherOrganization = authorization == "Bearer other-org-token"
            if request.url.path.hasSuffix("/profile") {
                return Self.profile(organization: isAnotherOrganization ? "another-org" : "test-org")
            }
            if isAnotherOrganization {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":77}}"#.utf8))
            }
            let count = originalUsageCount.withLock { $0 += 1; return $0 }
            return count == 1 ? Self.usage() : HTTPResponse(statusCode: 429, headers: [:], body: Data())
        }
        func makeProvider() -> ClaudeProvider {
            provider(files: files, http: http, keychain: keychain, store: store, now: { clock.withLock { $0 } })
        }
        let first = await makeProvider().refresh()
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await makeProvider().refresh()
        files.files[path] = credentials(access: "other-org-token")
        clock.withLock { $0 = start.addingTimeInterval(2) }
        let otherOrganization = await makeProvider().refresh()
        files.files[path] = credentials()
        clock.withLock { $0 = start.addingTimeInterval(3) }
        let originalOrganization = await makeProvider().refresh()

        XCTAssertEqual(first.line(label: "Session"), Self.session)
        XCTAssertNotNil(limited.usageRetryAfter)
        XCTAssertEqual(otherOrganization.line(label: "Session"), .progress(
            label: "Session", used: 77, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
        ))
        XCTAssertNil(otherOrganization.usageRetryAfter)
        XCTAssertEqual(otherOrganization.quotaObservedAt, start.addingTimeInterval(2))
        XCTAssertEqual(originalOrganization.line(label: "Session"), Self.session)
        XCTAssertEqual(originalOrganization.usageRetryAfter, limited.usageRetryAfter)
        XCTAssertEqual(originalOrganization.quotaObservedAt, start)
        XCTAssertEqual(originalUsageCount.withLock { $0 }, 2)
        XCTAssertEqual(http.requests.filter {
            $0.url.path.hasSuffix("/usage") && $0.headers["Authorization"] == "Bearer other-org-token"
        }.count, 1)
        XCTAssertEqual(files.files[metadataPath], accountOnlyMetadata)
    }

    func testFileFallbackKeepsKnownOrganizationBoundary() async {
        await assertRejectedFallback(metadata: claudeUsageTestIdentity(), profile: Self.profile(organization: "another-org"))
    }

    func testProfileRefreshWithoutExpiryKeepsUsingFreshTokenAcrossRequests() async {
        let files = FakeFiles([path: #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"single-use","expiresAt":1,"scopes":["user:profile"]}}"#])
        let refreshCount = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/token") {
                let count = refreshCount.withLock { $0 += 1; return $0 }
                return count == 1
                    ? HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"fresh"}"#.utf8))
                    : HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            if request.headers["Authorization"] == "Bearer old" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer fresh")
            return request.url.path.hasSuffix("/profile") ? Self.profile() : Self.usage()
        }
        let result = await provider(files: files, http: http).refresh()

        XCTAssertEqual(result.line(label: "Session"), Self.session)
        XCTAssertEqual(refreshCount.withLock { $0 }, 1)
        XCTAssertEqual(http.requests.map(\.url.path), [
            "/api/oauth/profile", "/v1/oauth/token", "/api/oauth/profile", "/api/oauth/usage"
        ])
        let saved = ClaudeAuthStore.parseCredentials(files.files[path] ?? "")?.claudeAiOauth
        XCTAssertEqual(saved?.accessToken, "fresh")
        XCTAssertEqual(saved?.refreshToken, "single-use")

        let repeated = await provider(files: files, http: http).refresh()

        XCTAssertEqual(repeated.line(label: "Session"), Self.session)
        XCTAssertEqual(refreshCount.withLock { $0 }, 1)
        XCTAssertEqual(Array(http.requests.suffix(2)).map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
    }

    func testVerifiedProfileStillRefreshesWhenUsageRejectsToken() async {
        let files = FakeFiles([path: #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}"#])
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/profile") { return Self.profile() }
            if request.url.path.hasSuffix("/token") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"access_token":"fresh"}"#.utf8))
            }
            if request.headers["Authorization"] == "Bearer old" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer fresh")
            return Self.usage()
        }
        let result = await provider(files: files, http: http).refresh()

        XCTAssertEqual(result.line(label: "Session"), Self.session)
        XCTAssertEqual(http.requests.map(\.url.path), [
            "/api/oauth/profile", "/api/oauth/usage", "/v1/oauth/token", "/api/oauth/usage"
        ])
    }

    private func assertRejectedFallback(
        metadata: String, profile: HTTPResponse, primaryRequestPath: String = "/api/oauth/usage"
    ) async {
        let files = FakeFiles([path: credentials(), metadataPath: metadata])
        let keychain = staleKeychain(files: files)
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer stale" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return request.url.path.hasSuffix("/profile") ? profile : Self.usage()
        }
        let result = await provider(files: files, http: http, keychain: keychain).refresh()

        XCTAssertTrue(result.lines.allSatisfy(\.isError))
        XCTAssertEqual(http.requests.map(\.url.path), [primaryRequestPath, "/api/oauth/profile"])
    }

    private func credentials(access: String = "file-token") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
    }

    private func staleKeychain(files: FakeFiles) -> ServiceKeychain {
        let keychain = ServiceKeychain()
        let auth = authStore(files: files, keychain: keychain)
        keychain.currentUserValues[auth.keychainServiceCandidates().first!] = credentials(access: "stale")
        return keychain
    }

    private func authStore(files: FakeFiles, keychain: KeychainAccessing) -> ClaudeAuthStore {
        ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                        files: files, keychain: keychain, allowsDesktopFallback: false)
    }

    private func provider(
        files: FakeFiles, http: HTTPClient, keychain: KeychainAccessing = FakeKeychain(),
        store: ClaudeUsageStateStore? = nil, now: @escaping @Sendable () -> Date = Date.init
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: authStore(files: files, keychain: keychain),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: store ?? isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: now, pricing: { TestPricing.bundled }
        )
    }

    private nonisolated static func profile(account: String = "account-a", organization: String = "test-org") -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"account":{"uuid":"\#(account)"},"organization":{"uuid":"\#(organization)"}}"#.utf8
        ))
    }

    private nonisolated static func usage() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42}}"#.utf8))
    }

    private static let session = MetricLine.progress(
        label: "Session", used: 42, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
    )
}
