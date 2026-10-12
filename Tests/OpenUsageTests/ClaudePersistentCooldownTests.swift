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
        let store = isolatedClaudeUsageStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let started = expectation(description: "First request")
        let http = RoutingHTTPClient { _ in
            started.fulfill()
            try await Task.sleep(for: .milliseconds(150))
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
        }
        let files = credentials()
        let first = provider(files: files, http: http, store: store)
        let second = provider(files: files, http: http, store: store)
        let task = Task { await first.refresh() }
        await fulfillment(of: [started], timeout: 2)
        let shared = await second.refresh()
        let original = await task.value
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(shared.quotaObservedAt, original.quotaObservedAt)
        XCTAssertNil(shared.liveQuotaObservedAt)
        XCTAssertNil(shared.warning)
    }

    func testConcurrentTokenRotationStillSharesOneUsageRequest() async throws {
        let store = isolatedClaudeUsageStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let tokenStarted = expectation(description: "Token refresh started")
        let files = credentials()
        files.files["/tmp/claude/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}"#
        let http = RoutingHTTPClient { request in
            if !request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                tokenStarted.fulfill()
                try await Task.sleep(for: .milliseconds(150))
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
        let shared = await second.refresh()
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
        XCTAssertTrue(result.lines.allSatisfy(\.isError))
        XCTAssertTrue(http.requests.isEmpty)
    }

    private func credentials() -> FakeFiles {
        FakeFiles([
            "/tmp/claude/.claude.json": claudeUsageTestIdentity(),
            "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        ])
    }

    private func provider(
        files: FakeFiles, http: HTTPClient, store: ClaudeUsageStateStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                                       files: files, keychain: FakeKeychain(), now: now),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: store,
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: now, pricing: { TestPricing.bundled }
        )
    }
}
