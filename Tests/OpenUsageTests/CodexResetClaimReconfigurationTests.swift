import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetClaimReconfigurationTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    private actor Counter {
        private var value = 0
        func next() -> Int {
            value += 1
            return value
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func provider(accountID: String = "account-A", http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": "/tmp/claim-reconfiguration"]),
                files: FakeFiles([
                    "/tmp/claim-reconfiguration/auth.json":
                        #"{"tokens":{"access_token":"fixture-token","account_id":"\#(accountID)"}}"#
                ]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: http)
        )
    }

    private func binding(accountID: String = "account-A") throws -> CodexResetClaimBinding {
        try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(
            auth: CodexAuth(tokens: CodexTokens(accessToken: "fixture-token", accountID: accountID)),
            source: .file(path: "/tmp/claim-reconfiguration/auth.json")
        )))
    }

    private nonisolated static func listResponse() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {"credits":[{"id":"credit-target","status":"available","expires_at":\(expiry.timeIntervalSince1970)}]}
        """.utf8))
    }

    func testLostConsumeResponseRetriesTheSameCreditAfterReconfiguration() async throws {
        let lists = Counter()
        let consumes = Counter()
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                if await lists.next() == 1 { return Self.listResponse() }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"credits":[]}"#.utf8))
            }
            if await consumes.next() == 1 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"already_redeemed"}"#.utf8))
        }
        let router = CodexResetClaimRouter(
            providers: [provider(http: http)], identityKeys: ["codex": "account-A"], refreshAfterClaim: { _ in }
        )
        let original = try XCTUnwrap(router.service(for: "codex"))
        let binding = try binding()
        let first = await original.claim(creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: binding)
        XCTAssertEqual(first, .failed)

        router.reconfigure(providers: [provider(http: http)], identityKeys: ["codex": "account-A"])
        let replacement = try XCTUnwrap(router.service(for: "codex"))
        let retry = await replacement.claim(creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: binding)

        XCTAssertEqual(retry, .success)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST", "POST"])
        let bodies = http.requests.filter { $0.method == "POST" }.compactMap(\.body)
        XCTAssertEqual(bodies.count, 2)
        let payloads = try bodies.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: String]) }
        XCTAssertEqual(payloads.first, payloads.last)
        XCTAssertEqual(payloads.last?["credit_id"], "credit-target")
        XCTAssertEqual(payloads.last?["redeem_request_id"], "retry")
    }

    func testReconfigurationDoesNotReuseARequestIDForAnotherAccount() async throws {
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL { return Self.listResponse() }
            throw URLError(.networkConnectionLost)
        }
        let router = CodexResetClaimRouter(
            providers: [provider(http: http)], identityKeys: ["codex": "account-A"], refreshAfterClaim: { _ in }
        )
        let original = try XCTUnwrap(router.service(for: "codex"))
        let first = await original.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: try binding()
        )
        XCTAssertEqual(first, .failed)
        let requestCount = http.requests.count

        router.reconfigure(
            providers: [provider(accountID: "account-B", http: http)], identityKeys: ["codex": "account-B"]
        )
        let replacement = try XCTUnwrap(router.service(for: "codex"))
        let retry = await replacement.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: try binding(accountID: "account-B")
        )

        XCTAssertEqual(retry, .failed)
        XCTAssertEqual(http.requests.count, requestCount, "the previous confirmation cannot migrate to another account")
    }

    func testConfirmedActionUsesTheCurrentServiceAfterReconfiguration() async throws {
        let http = RoutingHTTPClient { request in
            request.method == "GET" ? Self.listResponse()
                : HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let router = CodexResetClaimRouter(
            providers: [provider(http: http)], identityKeys: ["codex": "account-A"], refreshAfterClaim: { _ in }
        )
        let confirmed = try XCTUnwrap(router.claimAction(for: "codex", binding: binding()))
        router.reconfigure(providers: [provider(http: http)], identityKeys: ["codex": "account-A"])

        let outcome = await confirmed(Self.expiry, "confirmed")

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
    }

    func testConfirmedActionCannotMoveToAnotherAccountOrRemovedCard() async throws {
        for removeCard in [false, true] {
            let http = RoutingHTTPClient { _ in
                XCTFail("a stale account confirmation must not send requests")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
            let router = CodexResetClaimRouter(
                providers: [provider(http: http)], identityKeys: ["codex": "account-A"], refreshAfterClaim: { _ in }
            )
            let confirmed = try XCTUnwrap(router.claimAction(for: "codex", binding: binding()))
            router.reconfigure(
                providers: removeCard ? [] : [provider(accountID: "account-B", http: http)],
                identityKeys: removeCard ? [:] : ["codex": "account-B"]
            )

            let outcome = await confirmed(Self.expiry, "confirmed")

            XCTAssertEqual(outcome, .failed)
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testReconfigurationDoesNotDuplicateAnInFlightRequest() async throws {
        let reachedConsume = expectation(description: "original consume started")
        let consumes = Counter()
        let gate = Gate()
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL { return Self.listResponse() }
            if await consumes.next() == 1 {
                reachedConsume.fulfill()
                await gate.wait()
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let router = CodexResetClaimRouter(
            providers: [provider(http: http)], identityKeys: ["codex": "account-A"], refreshAfterClaim: { _ in }
        )
        let original = try XCTUnwrap(router.service(for: "codex"))
        let binding = try binding()
        let claim = Task {
            await original.claim(creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: binding)
        }
        await fulfillment(of: [reachedConsume], timeout: 2)

        router.reconfigure(providers: [provider(http: http)], identityKeys: ["codex": "account-A"])
        let replacement = try XCTUnwrap(router.service(for: "codex"))
        let duplicate = await replacement.claim(creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: binding)
        await gate.open()
        let outcome = await claim.value

        XCTAssertEqual(duplicate, .failed)
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
    }

    func testCredentialChangeBeforeCompletionSkipsRefreshAndPreservesTheServerOutcome() async throws {
        for consume in [false, true] {
            let reachedResponse = expectation(description: consume ? "consume pending" : "empty list pending")
            let gate = Gate()
            let http = RoutingHTTPClient { request in
                if consume, request.method == "GET" { return Self.listResponse() }
                reachedResponse.fulfill()
                await gate.wait()
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data((consume ? #"{"code":"reset"}"# : #"{"credits":[]}"#).utf8)
                )
            }
            var current = CodexAuthState(
                auth: CodexAuth(tokens: CodexTokens(accessToken: "fixture-token", accountID: "account-A")),
                source: .file(path: "/tmp/claim-reconfiguration/auth.json")
            )
            var refreshes = 0
            let service = CodexResetClaimService(
                usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in current },
                refreshAfterClaim: { refreshes += 1 }
            )
            let binding = try binding()
            let claim = Task {
                await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "completion", binding: binding)
            }
            await fulfillment(of: [reachedResponse], timeout: 2)
            current.auth.tokens = CodexTokens(accessToken: "other-token", accountID: "account-B")
            await gate.open()

            let outcome = await claim.value

            XCTAssertEqual(outcome, consume ? .success : .noCredit)
            XCTAssertEqual(refreshes, 0)
            XCTAssertEqual(http.requests.map(\.method), consume ? ["GET", "POST"] : ["GET"])
            XCTAssertEqual(Set(http.requests.compactMap { $0.headers["Authorization"] }), ["Bearer fixture-token"])
        }
    }
}
