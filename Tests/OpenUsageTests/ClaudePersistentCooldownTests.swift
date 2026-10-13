import os
import XCTest
@testable import OpenUsage

@MainActor
final class ClaudePersistentCooldownTests: XCTestCase {
    func testRestartTokenRotationAndAccountReturnKeepCooldownAndLastGoodAge() async throws {
        let store = isolatedClaudeUsageStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { _ in
            let attempt = count.withLock { $0 += 1; return $0 }
            return HTTPResponse(statusCode: attempt == 2 ? 429 : 200, headers: [:], body: Data(
                #"{"five_hour":{"utilization":25}}"#.utf8
            ))
        }
        let files = credentials()
        func makeProvider() -> ClaudeProvider {
            provider(files: files, http: http, store: store, now: { clock.withLock { $0 } })
        }
        let first = await makeProvider().refresh()
        XCTAssertEqual(first.quotaObservedAt, start)
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await makeProvider().refresh()
        XCTAssertEqual(limited.usageRetryAfter, start.addingTimeInterval(901))
        files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"rotated","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        clock.withLock { $0 = start.addingTimeInterval(100) }
        let restarted = await makeProvider().refresh()
        XCTAssertEqual(restarted.quotaObservedAt, start)
        XCTAssertNil(restarted.liveQuotaObservedAt)
        XCTAssertEqual(count.withLock { $0 }, 2)
        files.files["/tmp/claude/.claude.json"] = claudeUsageTestIdentity("account-b")
        let otherAccount = await makeProvider().refresh()
        XCTAssertNil(otherAccount.usageRetryAfter)
        XCTAssertEqual(count.withLock { $0 }, 3)
        files.files["/tmp/claude/.claude.json"] = claudeUsageTestIdentity()
        let returned = await makeProvider().refresh()
        XCTAssertEqual(returned.usageRetryAfter, limited.usageRetryAfter)
        XCTAssertEqual(returned.quotaObservedAt, start)
        XCTAssertEqual(count.withLock { $0 }, 3)
        clock.withLock { $0 = start.addingTimeInterval(902) }
        let recovered = await makeProvider().refresh()
        XCTAssertNil(recovered.usageRetryAfter)
        XCTAssertEqual(recovered.liveQuotaObservedAt, start.addingTimeInterval(902))
    }

    func testConcurrentProvidersShareOneUsageRequest() async throws {
        let contended = expectation(description: "Second provider reached the account lock")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let started = expectation(description: "First request")
        let gate = UsageGate()
        let http = RoutingHTTPClient { _ in
            started.fulfill()
            await gate.wait()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        }
        let files = credentials()
        let first = provider(files: files, http: http, store: store)
        let second = provider(files: files, http: http, store: store)
        let task = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let sharedTask = Task { await second.refresh() }
        await fulfillment(of: [contended], timeout: 2)
        await gate.open()
        let shared = await sharedTask.value
        let original = await task.value
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(shared.quotaObservedAt, original.quotaObservedAt)
        XCTAssertNil(shared.liveQuotaObservedAt)
        XCTAssertNil(shared.warning)
    }

    func testBackwardClockChangeDoesNotReuseAnEarlierCompletedRequest() async {
        let store = isolatedClaudeUsageStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let files = credentials()
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8)
        ))
        let first = await provider(files: files, http: http, store: store, now: { clock.withLock { $0 } }).refresh()
        XCTAssertEqual(first.quotaObservedAt, start)
        clock.withLock { $0 = start.addingTimeInterval(-3600) }
        let second = await provider(files: files, http: http, store: store, now: { clock.withLock { $0 } }).refresh()
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(second.liveQuotaObservedAt, start.addingTimeInterval(-3600))
    }

    func testConcurrentTokenRotationStillSharesOneUsageRequest() async throws {
        let contended = expectation(description: "Second provider waits during token rotation")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let tokenStarted = expectation(description: "Token refresh started")
        let gate = UsageGate()
        let files = credentials()
        files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}"#
        let http = RoutingHTTPClient { request in
            if !request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                tokenStarted.fulfill()
                await gate.wait()
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        }
        let first = provider(files: files, http: http, store: store)
        let second = provider(files: files, http: http, store: store)
        let task = Task { await first.refresh() }
        await fulfillment(of: [tokenStarted], timeout: 2)
        let sharedTask = Task { await second.refresh() }
        await fulfillment(of: [contended], timeout: 2)
        await gate.open()
        let shared = await sharedTask.value
        let original = await task.value
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(shared.quotaObservedAt, original.quotaObservedAt)
        XCTAssertNotNil(shared.quotaObservedAt)
        XCTAssertNil(shared.liveQuotaObservedAt)
    }

    func testMissingAccountIdentityDoesNotSendUsageRequest() async {
        let store = isolatedClaudeUsageStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let files = credentials()
        files.files["/tmp/claude/.claude.json"] = nil
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let result = await provider(files: files, http: http, store: store).refresh()
        XCTAssertFalse(result.lines.isEmpty)
        XCTAssertTrue(result.lines.allSatisfy(\.isError))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testConcurrentFailuresAreSharedWithoutBlockingLaterRetry() async throws {
        for failure in [ClaudeUsageError.connectionFailed, .requestFailed(503), .invalidResponse] {
            let contended = expectation(description: "Second provider waits for \(failure)")
            let started = expectation(description: "First failing request")
            let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
            let gate = UsageGate()
            let count = OSAllocatedUnfairLock(initialState: 0)
            let http = RoutingHTTPClient { _ in
                let attempt = count.withLock { $0 += 1; return $0 }
                if attempt == 1 {
                    started.fulfill()
                    await gate.wait()
                    switch failure {
                    case .connectionFailed: throw URLError(.notConnectedToInternet)
                    case .requestFailed(let status): return HTTPResponse(statusCode: status, headers: [:], body: Data())
                    case .invalidResponse: return HTTPResponse(statusCode: 200, headers: [:], body: Data("invalid".utf8))
                    }
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
            }
            let files = credentials()
            let first = provider(files: files, http: http, store: store)
            let second = provider(files: files, http: http, store: store)
            let original = Task { await first.refresh() }
            await fulfillment(of: [started], timeout: 2)
            let waiting = Task { await second.refresh() }
            await fulfillment(of: [contended], timeout: 2)
            await gate.open()
            let firstResult = await original.value
            let shared = await waiting.value

            XCTAssertEqual(count.withLock { $0 }, 1, "overlapping failure must not trigger another HTTP request")
            XCTAssertFalse(firstResult.lines.isEmpty)
            XCTAssertTrue(firstResult.lines.allSatisfy(\.isError))
            XCTAssertEqual(shared.lines, firstResult.lines)

            let recovered = await provider(files: files, http: http, store: store).refresh()
            XCTAssertNotNil(recovered.quotaObservedAt)
            XCTAssertEqual(count.withLock { $0 }, 2, "a later request may retry an ordinary failure")
        }
    }

    func testConcurrentTokenRefreshFailuresHaveTheSameError() async throws {
        for disconnected in [false, true] {
            let started = expectation(description: "Token refresh started")
            let contended = expectation(description: "Second provider waits for token refresh")
            let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
            let gate = UsageGate()
            let files = credentials()
            files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}"#
            let http = RoutingHTTPClient { _ in
                started.fulfill()
                await gate.wait()
                if disconnected { throw URLError(.notConnectedToInternet) }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("invalid".utf8))
            }
            let first = provider(files: files, http: http, store: store)
            let second = provider(files: files, http: http, store: store)
            let original = Task { await first.refresh() }
            await fulfillment(of: [started], timeout: 2)
            let waiting = Task { await second.refresh() }
            await fulfillment(of: [contended], timeout: 2)
            await gate.open()
            let firstResult = await original.value
            let shared = await waiting.value
            XCTAssertEqual(http.requests.count, 1)
            XCTAssertFalse(firstResult.lines.isEmpty)
            XCTAssertTrue(firstResult.lines.allSatisfy(\.isError))
            XCTAssertEqual(firstResult.lines, shared.lines)
            XCTAssertEqual(firstResult.errorCategory, shared.errorCategory)
        }
    }

    func testConcurrentRevokedRefreshTokensShareAuthenticationFailure() async throws {
        let started = expectation(description: "Revoked token refresh started")
        let contended = expectation(description: "Second provider waits for revoked credentials")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        let gate = UsageGate()
        let files = credentials()
        files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"revoked-access","refreshToken":"revoked-refresh","expiresAt":1,"scopes":["user:profile"]}}"#
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { _ in
            if calls.withLock({ $0 += 1; return $0 }) == 1 { started.fulfill() }
            await gate.wait()
            return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let first = provider(files: files, http: http, store: store)
        let second = provider(files: files, http: http, store: store)
        let original = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let waiting = Task { await second.refresh() }
        await fulfillment(of: [contended], timeout: 2)
        await gate.open()

        let firstResult = await original.value
        let shared = await waiting.value
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(firstResult.errorCategory, .authExpired)
        XCTAssertEqual(shared.lines, firstResult.lines)
        let savedFiles = try FileManager.default.contentsOfDirectory(at: store.directory, includingPropertiesForKeys: nil)
        for file in savedFiles where file.pathExtension == "json" {
            let saved = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(saved.contains("revoked-access"))
            XCTAssertFalse(saved.contains("revoked-refresh"))
        }
        _ = await first.refresh()
        XCTAssertEqual(http.requests.count, 2, "A later request may retry the same credentials")
    }

    func testConcurrentUnauthorizedRetrySharesFailureAfterTokenRotation() async throws {
        let started = expectation(description: "Unauthorized usage request started")
        let contended = expectation(description: "Second provider waits for unauthorized credentials")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        let gate = UsageGate()
        let files = credentials()
        files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        let http = RoutingHTTPClient { request in
            if !request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"new","refresh_token":"new-refresh","expires_in":3600}"#.utf8
                ))
            }
            if request.headers["Authorization"] == "Bearer old" {
                started.fulfill()
                await gate.wait()
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let first = provider(files: files, http: http, store: store)
        let second = provider(files: files, http: http, store: store)
        let original = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let waiting = Task { await second.refresh() }
        await fulfillment(of: [contended], timeout: 2)
        await gate.open()

        let firstResult = await original.value
        let shared = await waiting.value
        XCTAssertEqual(http.requests.count, 3, "The waiter must reuse the failed retry with rotated credentials")
        XCTAssertEqual(firstResult.errorCategory, .authExpired)
        XCTAssertEqual(shared.lines, firstResult.lines)
    }

    func testConcurrentAuthenticationFailureDoesNotRejectAnotherRefreshToken() async throws {
        let started = expectation(description: "Revoked refresh token request started")
        let contended = expectation(description: "Valid credentials wait for the same account")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        let gate = UsageGate()
        let revokedFiles = credentials()
        let validFiles = credentials()
        revokedFiles.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"shared-access","refreshToken":"revoked-refresh","expiresAt":1,"scopes":["user:profile"]}}"#
        validFiles.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"shared-access","refreshToken":"valid-refresh","expiresAt":1,"scopes":["user:profile"]}}"#
        let http = RoutingHTTPClient { request in
            if !request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                let parameters = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.body))
                if parameters["refresh_token"] == "revoked-refresh" {
                    started.fulfill()
                    await gate.wait()
                    return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"valid-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8
                ))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        }
        let first = provider(files: revokedFiles, http: http, store: store)
        let second = provider(files: validFiles, http: http, store: store)
        let original = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let waiting = Task { await second.refresh() }
        await fulfillment(of: [contended], timeout: 2)
        await gate.open()

        let failed = await original.value
        let recovered = await waiting.value
        XCTAssertEqual(failed.errorCategory, .authExpired)
        XCTAssertNotNil(recovered.liveQuotaObservedAt)
        XCTAssertEqual(http.requests.count, 3)
    }

    func testOAuthEndpointsKeepSeparateCooldownsAndLastGoodUsage() async throws {
        let store = isolatedClaudeUsageStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let productionCalls = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            if request.url.host == "custom.example" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":75}}"#.utf8))
            }
            let attempt = productionCalls.withLock { $0 += 1; return $0 }
            return HTTPResponse(statusCode: attempt == 1 ? 200 : 429, headers: [:], body: Data(
                #"{"five_hour":{"utilization":25}}"#.utf8
            ))
        }
        let files = credentials()
        let production = provider(files: files, http: http, store: store, now: { clock.withLock { $0 } })
        _ = await production.refresh()
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await production.refresh()
        clock.withLock { $0 = start.addingTimeInterval(2) }
        let custom = await provider(
            files: files, http: http, store: store, now: { clock.withLock { $0 } },
            environment: ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://custom.example"]
        ).refresh()
        clock.withLock { $0 = start.addingTimeInterval(3) }
        let returned = await production.refresh()

        XCTAssertNil(custom.usageRetryAfter)
        XCTAssertEqual(custom.liveQuotaObservedAt, start.addingTimeInterval(2))
        XCTAssertEqual(custom.line(label: "Session"), .progress(label: "Session", used: 75, limit: 100,
                                                               format: .percent, periodDurationMs: MetricPeriod.sessionMs))
        XCTAssertEqual(returned.usageRetryAfter, limited.usageRetryAfter)
        XCTAssertEqual(returned.quotaObservedAt, start)
        XCTAssertEqual(returned.line(label: "Session"), limited.line(label: "Session"))
        XCTAssertEqual(http.requests.count, 3)
    }

    private actor UsageGate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuations.append($0) }
        }

        func open() {
            opened = true
            for continuation in continuations { continuation.resume() }
            continuations.removeAll()
        }
    }

    private func credentials() -> FakeFiles {
        FakeFiles([
            "/tmp/claude/.claude.json": claudeUsageTestIdentity(),
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        ])
    }

    private func provider(
        files: FakeFiles, http: HTTPClient, store: ClaudeUsageStateStore,
        now: @escaping @Sendable () -> Date = Date.init,
        environment: [String: String] = [:]
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(environment.merging(["CLAUDE_CONFIG_DIR": "/tmp/claude"]) { _, value in value }),
                                       files: files, keychain: FakeKeychain(), now: now),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: store,
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: now, pricing: { TestPricing.bundled }
        )
    }
}
