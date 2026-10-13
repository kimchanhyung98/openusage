import os
import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeIdentityRecoveryTests: XCTestCase {
    private let path = "/tmp/claude/.credentials.json"
    private let metadataPath = "/tmp/claude/.claude.json"

    func testValidLoginWithoutLocalMetadataRecoversUsage() async {
        let files = FakeFiles([path: credentials()])
        let http = RoutingHTTPClient { request in
            request.url.path.hasSuffix("/profile") ? Self.profile() : Self.usage()
        }
        let result = await provider(files: files, http: http).refresh()

        XCTAssertEqual(result.line(label: "Session"), Self.session)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer token" })
        XCTAssertNil(files.files[metadataPath])
    }

    func testVerifiedFileFallbackCannotUseAnotherAccountsIdentity() async {
        let files = FakeFiles([path: credentials(), metadataPath: claudeUsageTestIdentity()])
        let keychain = ServiceKeychain()
        let auth = authStore(files: files, keychain: keychain)
        keychain.currentUserValues[auth.keychainServiceCandidates().first!] = credentials(access: "stale")
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer stale" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return request.url.path.hasSuffix("/profile") ? Self.profile(account: "account-b") : Self.usage()
        }
        let result = await provider(files: files, http: http, keychain: keychain).refresh()

        XCTAssertTrue(result.lines.allSatisfy(\.isError))
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/usage", "/api/oauth/profile"])
        XCTAssertFalse(http.requests.contains { $0.url.path.hasSuffix("/usage") && $0.headers["Authorization"] == "Bearer token" })
    }

    func testMetadataLossAndTokenReplacementKeepSavedCooldownAndLastGood() async {
        let store = isolatedClaudeUsageStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let files = FakeFiles([path: credentials(), metadataPath: claudeUsageTestIdentity()])
        let usageCount = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/profile") { return Self.profile(account: "ACCOUNT-A") }
            let count = usageCount.withLock { $0 += 1; return $0 }
            return count == 1 ? Self.usage() : HTTPResponse(statusCode: 429, headers: [:], body: Data())
        }
        func makeProvider() -> ClaudeProvider {
            provider(files: files, http: http, store: store, now: { clock.withLock { $0 } })
        }
        _ = await makeProvider().refresh()
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await makeProvider().refresh()
        files.files[metadataPath] = nil
        files.files[path] = credentials(access: "rotated")
        clock.withLock { $0 = start.addingTimeInterval(2) }
        let recovered = await makeProvider().refresh()

        XCTAssertEqual(recovered.usageRetryAfter, limited.usageRetryAfter)
        XCTAssertNotNil(recovered.usageRetryAfter)
        XCTAssertEqual(recovered.quotaObservedAt, start)
        XCTAssertNil(recovered.liveQuotaObservedAt)
        XCTAssertEqual(recovered.line(label: "Session"), Self.session)
        XCTAssertEqual(usageCount.withLock { $0 }, 2)
        XCTAssertEqual(http.requests.last?.url.path, "/api/oauth/profile")
    }

    func testExpiredUnidentifiedLoginRefreshesAndPersistsBeforeRecovery() async {
        let files = FakeFiles([path: refreshableCredentials])
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/token") { return Self.rotatedToken() }
            if request.headers["Authorization"] == "Bearer token" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return request.url.path.hasSuffix("/profile") ? Self.profile() : Self.usage()
        }
        let result = await provider(files: files, http: http).refresh()

        XCTAssertEqual(result.line(label: "Session"), Self.session)
        XCTAssertEqual(http.requests.map(\.url.path), [
            "/api/oauth/profile", "/v1/oauth/token", "/api/oauth/profile", "/api/oauth/usage"
        ])
        let saved = ClaudeAuthStore.parseCredentials(files.files[path] ?? "")?.claudeAiOauth
        XCTAssertEqual(saved?.accessToken, "fresh")
        XCTAssertEqual(saved?.refreshToken, "refresh-2")
        XCTAssertNil(files.files[metadataPath])
    }

    func testLoginChangedDuringProfileDiscardsOldResult() async {
        let path = path
        let metadataPath = metadataPath
        let files = FakeFiles([path: credentials()])
        let replacement = credentials(access: "account-b-token")
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/profile") {
                files.files[path] = replacement
                files.files[metadataPath] = claudeUsageTestIdentity("account-b")
                return Self.profile()
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer account-b-token")
            return Self.usage()
        }
        let result = await provider(files: files, http: http).refresh()

        XCTAssertEqual(result.line(label: "Session"), Self.session)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
    }

    func testProfileUsesConfiguredAPIOriginAndPath() async {
        let files = FakeFiles([path: credentials()])
        let http = RoutingHTTPClient { request in
            request.url.path.hasSuffix("/profile") ? Self.profile() : Self.usage()
        }
        let result = await provider(
            files: files, http: http, environment: ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://custom.example/prefix"]
        ).refresh()

        XCTAssertEqual(result.line(label: "Session"), Self.session)
        XCTAssertEqual(http.requests.map(\.url.absoluteString), [
            "https://custom.example/prefix/api/oauth/profile", "https://custom.example/prefix/api/oauth/usage"
        ])
    }

    func testProfileFailuresNeverSendUsageOrRefreshTokens() async {
        let responses = [
            HTTPResponse(statusCode: 429, headers: [:], body: Data()),
            HTTPResponse(statusCode: 503, headers: [:], body: Data()),
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"account":{"uuid":"a"}}"#.utf8)),
            Self.profile(account: " "),
            Self.profile(account: "a|b")
        ]
        for response in responses {
            let files = FakeFiles([path: refreshableCredentials])
            let http = FakeHTTPClient(response: response)
            let result = await provider(files: files, http: http).refresh()

            XCTAssertFalse(result.lines.isEmpty)
            XCTAssertTrue(result.lines.allSatisfy(\.isError))
            XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
            XCTAssertEqual(files.files[path], refreshableCredentials)
        }
    }

    func testConcurrentUnidentifiedLoginsShareTokenRotationAndUsage() async {
        let started = expectation(description: "Profile started")
        let contended = expectation(description: "Second caller waits for recovery")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        let gate = ProfileGate()
        let files = FakeFiles([path: refreshableCredentials])
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer token" {
                started.fulfill()
                await gate.wait()
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url.path.hasSuffix("/token") { return Self.rotatedToken() }
            return request.url.path.hasSuffix("/profile") ? Self.profile() : Self.usage()
        }
        let first = provider(files: files, http: http, store: store)
        let second = provider(files: files, http: http, store: store)
        let firstTask = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let secondTask = Task { await second.refresh() }
        await fulfillment(of: [contended], timeout: 2)
        await gate.open()
        let original = await firstTask.value
        let shared = await secondTask.value

        XCTAssertEqual(original.line(label: "Session"), Self.session)
        XCTAssertEqual(shared.line(label: "Session"), Self.session)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/token") }.count, 1)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/usage") }.count, 1)
        XCTAssertEqual(shared.quotaObservedAt, original.quotaObservedAt)
        XCTAssertNil(shared.liveQuotaObservedAt)
    }

    private let refreshableCredentials = #"{"claudeAiOauth":{"accessToken":"token","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}"#

    private func credentials(access: String = "token") -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(access)","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
    }

    private func authStore(
        files: FakeFiles, keychain: KeychainAccessing, environment: [String: String] = [:]
    ) -> ClaudeAuthStore {
        ClaudeAuthStore(environment: FakeEnvironment(environment.merging(["CLAUDE_CONFIG_DIR": "/tmp/claude"]) { _, value in value }),
                        files: files, keychain: keychain, allowsDesktopFallback: false)
    }

    private func provider(
        files: FakeFiles, http: HTTPClient, keychain: KeychainAccessing = FakeKeychain(),
        store: ClaudeUsageStateStore? = nil, now: @escaping @Sendable () -> Date = Date.init,
        environment: [String: String] = [:]
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: authStore(files: files, keychain: keychain, environment: environment),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: store ?? isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: now, pricing: { TestPricing.bundled }
        )
    }

    private nonisolated static func profile(account: String = "account-a") -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"account":{"uuid":"\#(account)"},"organization":{"uuid":"test-org"}}"#.utf8
        ))
    }

    private nonisolated static func usage() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42}}"#.utf8))
    }

    private nonisolated static func rotatedToken() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"access_token":"fresh","refresh_token":"refresh-2","expires_in":3600}"#.utf8
        ))
    }

    private actor ProfileGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
        }
    }

    private static let session = MetricLine.progress(
        label: "Session", used: 42, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
    )
}
