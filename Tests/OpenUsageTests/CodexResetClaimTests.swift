import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetClaimTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    private nonisolated static func state(
        token: String = "token-123", accountID: String? = "acct-456",
        source: CodexAuthState.Source = .file(path: "/fixture/auth.json")
    ) -> CodexAuthState {
        CodexAuthState(auth: CodexAuth(tokens: CodexTokens(accessToken: token, accountID: accountID)), source: source)
    }

    private nonisolated static var binding: CodexResetClaimBinding {
        CodexResetClaimBinding(authState: state())!
    }

    private final class RefreshCounter: @unchecked Sendable {
        var count = 0
    }

    private nonisolated static func listBody(expiry: Date = expiry, status: String = "available") -> Data {
        Data("""
        {"credits": [
            {"id": "RateLimitResetCredit_other", "status": "available",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry.addingTimeInterval(999_999)))"},
            {"id": "RateLimitResetCredit_target", "status": "\(status)",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry))"}
        ], "available_count": 2}
        """.utf8)
    }

    private nonisolated static func consumeBody(code: String) -> Data {
        Data(#"{"code": "\#(code)", "windows_reset": 2}"#.utf8)
    }

    /// list GET·consume POST 라우팅 — 그 외 요청은 테스트 실패
    private func makeService(
        listStatus: Int = 200,
        listBody: Data = listBody(),
        consumeStatus: Int = 200,
        consumeBody: Data = consumeBody(code: "reset"),
        refreshes: RefreshCounter = RefreshCounter()
    ) -> (CodexResetClaimService, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: listStatus, headers: [:], body: listBody)
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: consumeStatus, headers: [:], body: consumeBody)
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { source, _ in
                XCTAssertEqual(source, Self.binding.source)
                return Self.state()
            },
            refreshAfterClaim: { refreshes.count += 1 }
        )
        return (service, http)
    }

    // MARK: - Consume request shape

    func testConsumeRequestShape() async throws {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "reset"))
        }
        let client = CodexUsageClient(http: http)
        _ = try await client.consumeResetCredit(
            accessToken: "token-123", accountID: "acct-456",
            creditID: "RateLimitResetCredit_target", redeemRequestID: "11111111-2222-3333-4444-555555555555"
        )

        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CodexUsageClient.consumeResetCreditURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer token-123")
        XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "acct-456")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")

        let body = try XCTUnwrap(request.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, [
            "redeem_request_id": "11111111-2222-3333-4444-555555555555",
            "credit_id": "RateLimitResetCredit_target"
        ])
    }

    // MARK: - Outcome decoding

    func testConsumeOutcomeDecodesAllProtocolCodes() {
        func outcome(_ code: String, status: Int = 200) -> ResetClaimOutcome {
            CodexResetClaimService.outcome(fromConsume:
                HTTPResponse(statusCode: status, headers: [:], body: Self.consumeBody(code: code)))
        }
        XCTAssertEqual(outcome("reset"), .success)
        // lost-response 재시도에서 idempotency key가 이미 소비한 credit — 여전히 success
        XCTAssertEqual(outcome("already_redeemed"), .success)
        XCTAssertEqual(outcome("nothing_to_reset"), .nothingToReset)
        XCTAssertEqual(outcome("no_credit"), .noCredit)
        XCTAssertEqual(outcome("something_new"), .failed)      // 알 수 없는 code
        XCTAssertEqual(outcome("reset", status: 500), .failed) // non-2xx가 파싱 가능한 body보다 우선
        XCTAssertEqual(
            CodexResetClaimService.outcome(fromConsume:
                HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))),
            .failed
        )
    }

    // MARK: - Expiry → credit-id matching

    func testCreditMatchingByExpiry() throws {
        let body = try XCTUnwrap(ProviderParse.jsonObject(Self.listBody()))
        XCTAssertEqual(
            CodexResetClaimService.creditID(in: body, expiringAt: Self.expiry),
            "RateLimitResetCredit_target"
        )
        // sub-second 절삭은 허용, 다른 credit의 expiry는 불허
        XCTAssertEqual(
            CodexResetClaimService.creditID(in: body, expiringAt: Self.expiry.addingTimeInterval(0.5)),
            "RateLimitResetCredit_target"
        )
        XCTAssertNil(CodexResetClaimService.creditID(in: body, expiringAt: Self.expiry.addingTimeInterval(3600)))
    }

    func testCreditMatchingSkipsNonAvailableStatusButKeepsMissingStatus() throws {
        let redeemed = try XCTUnwrap(ProviderParse.jsonObject(Self.listBody(status: "redeemed")))
        XCTAssertNil(CodexResetClaimService.creditID(in: redeemed, expiringAt: Self.expiry))

        // `status` 필드 부재는 available로 간주 — mapper 필터와 동일
        let noStatus = try XCTUnwrap(ProviderParse.jsonObject(Data(
            #"{"credits": [{"id": "RateLimitResetCredit_bare", "expires_at": \#(Self.expiry.timeIntervalSince1970)}]}"#.utf8
        )))
        XCTAssertEqual(
            CodexResetClaimService.creditID(in: noStatus, expiringAt: Self.expiry),
            "RateLimitResetCredit_bare"
        )
    }

    // MARK: - Full claim flow

    func testClaimMatchesCreditConsumesItAndRefreshes() async throws {
        let refreshes = RefreshCounter()
        let (service, http) = makeService(refreshes: refreshes)

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(refreshes.count, 1, "a successful claim forces a Codex refresh before returning")
        XCTAssertEqual(http.requests.map(\.url),
                       [CodexUsageClient.resetCreditsURL, CodexUsageClient.consumeResetCreditURL])
        let consumeRequest = try XCTUnwrap(http.requests.last)
        let body = try XCTUnwrap(consumeRequest.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "RateLimitResetCredit_target", "the freshly matched id, by expiry")
        XCTAssertEqual(payload["redeem_request_id"], "redeem-1", "the caller's idempotency key, verbatim")
    }

    func testClaimWithNoMatchingCreditIsNoCreditWithoutConsuming() async {
        let refreshes = RefreshCounter()
        let (service, http) = makeService(
            listBody: Data(#"{"credits": [], "available_count": 0}"#.utf8),
            refreshes: refreshes
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)

        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL], "no consume POST is ever sent")
        XCTAssertEqual(refreshes.count, 1, "the raced-away credit triggers a refresh to reconcile the timeline")
    }

    func testClaimFailuresNeverRefreshAndNeverThrow() async {
        let refreshes = RefreshCounter()

        // list fetch 실패
        let (listFails, _) = makeService(listStatus: 503, refreshes: refreshes)
        let listOutcome = await listFails.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)
        XCTAssertEqual(listOutcome, .failed)

        // consume이 non-2xx 반환
        let (consumeFails, _) = makeService(
            consumeStatus: 500, consumeBody: Data("gateway error".utf8), refreshes: refreshes
        )
        let consumeOutcome = await consumeFails.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)
        XCTAssertEqual(consumeOutcome, .failed)

        // credential 전무
        let noCredentials = CodexResetClaimService(
            usageClient: CodexUsageClient(http: RoutingHTTPClient { _ in
                XCTFail("no request should be sent without credentials")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }),
            credentialLoader: { _, _ in nil },
            refreshAfterClaim: { refreshes.count += 1 }
        )
        let credentialOutcome = await noCredentials.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)
        XCTAssertEqual(credentialOutcome, .failed)

        XCTAssertEqual(refreshes.count, 0, "failures leave the snapshot alone")
    }

    func testClaimNothingToResetKeepsCreditAndRefreshes() async {
        let refreshes = RefreshCounter()
        let (service, _) = makeService(
            consumeBody: Self.consumeBody(code: "nothing_to_reset"),
            refreshes: refreshes
        )

        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)

        XCTAssertEqual(outcome, .nothingToReset)
        XCTAssertEqual(refreshes.count, 1)
    }

    // MARK: - Idempotent replay

    func testRetryWithSameKeyReplaysTheConsumeInsteadOfNoCredit() async throws {
        // 같은 idempotency key의 재시도가 credit 소멸 후 도착 — 캐시된 credit id로 replay, `.noCredit` 오보 금지
        let listBodies = [Self.listBody(), Data(#"{"credits": [], "available_count": 0}"#.utf8)]
        let listCalls = RefreshCounter()
        let consumeCodes = ["reset", "already_redeemed"]
        let consumeCalls = RefreshCounter()
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                defer { listCalls.count += 1 }
                return HTTPResponse(statusCode: 200, headers: [:], body: listBodies[min(listCalls.count, 1)])
            case CodexUsageClient.consumeResetCreditURL:
                defer { consumeCalls.count += 1 }
                return HTTPResponse(statusCode: 200, headers: [:],
                                    body: Self.consumeBody(code: consumeCodes[min(consumeCalls.count, 1)]))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { source, _ in
                XCTAssertEqual(source, Self.binding.source)
                return Self.state()
            }
        )

        let first = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)
        let retry = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding)

        XCTAssertEqual(first, .success)
        XCTAssertEqual(retry, .success, "already_redeemed proves the original claim landed")
        XCTAssertEqual(listCalls.count, 1, "the replay skips re-matching entirely")
        XCTAssertEqual(consumeCalls.count, 2)
        let replay = try XCTUnwrap(http.requests.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(replay.body)) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "RateLimitResetCredit_target", "the originally matched credit id")
    }

    // MARK: - Credential binding

    func testClaimFailsWhenTheBoundCredentialIsRejected() async {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { _, _ in Self.state() }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL])
    }

    func testConsumeNeverFallsBackToADifferentAccount() async throws {
        let original = Self.state(token: "shared-token", accountID: "acct-A")
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: original))
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            }
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "acct-A")
            return HTTPResponse(statusCode: 403, headers: [:], body: Data())
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { source, _ in
                XCTAssertEqual(source, original.source)
                return original
            }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: binding
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(http.requests.last?.headers["ChatGPT-Account-Id"], "acct-A")
    }

    func testChangedAccountBeforeClaimSendsNoRequests() async throws {
        let http = RoutingHTTPClient { _ in
            XCTFail("a stale confirmation must not make a request")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { _, _ in Self.state(token: "token-B", accountID: "acct-B") }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testChangedAccountDuringCreditFetchNeverConsumes() async {
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
        }
        var loads = 0
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { _, _ in
                loads += 1
                return loads == 1 ? Self.state() : Self.state(token: "token-B", accountID: "acct-B")
            }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.resetCreditsURL])
    }

    func testBindingInvalidatedDuringCredentialReadSendsNoRequests() async {
        let http = RoutingHTTPClient { _ in
            XCTFail("the router binding changed during credential loading")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        var current = true
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { _, _ in
                current = false
                return Self.state()
            },
            isCurrent: { current }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1", binding: Self.binding
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testReplayCannotReuseARequestIDForAnotherBindingOrExpiry() async throws {
        let http = RoutingHTTPClient { request in
            HTTPResponse(statusCode: 200, headers: [:], body: request.method == "GET"
                         ? Self.listBody() : Self.consumeBody(code: "already_redeemed"))
        }
        var current = Self.state()
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in current }
        )
        let first = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "same-key", binding: Self.binding
        )
        XCTAssertEqual(first, .success)
        let originalRequestCount = http.requests.count
        let changedExpiry = await service.claim(
            creditExpiringAt: Self.expiry.addingTimeInterval(60), redeemRequestID: "same-key", binding: Self.binding
        )
        current = Self.state(token: "token-B", accountID: "acct-B")
        let otherBinding = try XCTUnwrap(CodexResetClaimBinding(authState: current))
        let changedAccount = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "same-key", binding: otherBinding
        )

        XCTAssertEqual(changedExpiry, .failed)
        XCTAssertEqual(changedAccount, .failed)
        XCTAssertEqual(http.requests.count, originalRequestCount)
    }

    func testResponseLossRetriesTheSameCreditWithoutRelisting() async throws {
        let consumeCalls = RefreshCounter()
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            }
            consumeCalls.count += 1
            if consumeCalls.count == 1 { throw URLError(.networkConnectionLost) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.consumeBody(code: "already_redeemed"))
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in Self.state() }
        )
        let first = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "lost-response", binding: Self.binding
        )
        let retry = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "lost-response", binding: Self.binding
        )

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(retry, .success)
        XCTAssertEqual(http.requests.filter { $0.method == "GET" }.count, 1)
        let posts = http.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.first?.body, posts.last?.body)
        XCTAssertEqual(posts.first?.headers["Authorization"], posts.last?.headers["Authorization"])
    }

    func testCancelledClaimDuringCreditFetchNeverConsumes() async {
        let reachedList = expectation(description: "credit list started")
        let gate = ClaimGate()
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                reachedList.fulfill()
                await gate.wait()
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in Self.state() }
        )
        let task = Task {
            await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "cancelled", binding: Self.binding)
        }
        await fulfillment(of: [reachedList], timeout: 2)
        task.cancel()
        await gate.open()
        let outcome = await task.value

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
    }

    func testConcurrentClaimsWithTheSameRequestIDConsumeOnlyOnce() async {
        let reachedList = expectation(description: "first credit list started")
        let gate = ClaimGate()
        let lists = RefreshCounter()
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                lists.count += 1
                if lists.count == 1 {
                    reachedList.fulfill()
                    await gate.wait()
                }
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: request.method == "GET"
                                ? Self.listBody() : Self.consumeBody(code: "reset"))
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in Self.state() }
        )
        let first = Task { await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "shared", binding: Self.binding) }
        await fulfillment(of: [reachedList], timeout: 2)
        let duplicate = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "shared", binding: Self.binding)
        await gate.open()
        let outcome = await first.value
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(duplicate, .failed)
        XCTAssertEqual(http.requests.filter { $0.method == "POST" }.count, 1)
    }

    private actor ClaimGate {
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
}
