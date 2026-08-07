import XCTest
@testable import OpenUsage

/// The per-card claim router: every card's service must authenticate with THAT card's credential —
/// a claim is irreversible, so routing a managed-profile card's claim through the default card's
/// login would spend the wrong account. Proven here by claiming through each service and asserting
/// the bearer token on the wire, plus the per-card `refreshAfterClaim` target.
@MainActor
final class CodexResetClaimRouterTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)

    /// Records values from an escaping async context.
    private final class Recorder: @unchecked Sendable {
        var values: [String] = []
    }

    private nonisolated static func auth(token: String, accountID: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }

    private nonisolated static func listBody() -> Data {
        Data("""
        {"credits": [
            {"id": "RateLimitResetCredit_target", "status": "available",
             "expires_at": "\(OpenUsageISO8601.string(from: expiry))"}
        ], "available_count": 1}
        """.utf8)
    }

    /// Routes the list GET and consume POST, always succeeding.
    private func makeHTTP() -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Self.listBody())
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code": "reset"}"#.utf8))
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
    }

    /// The default card, faithful to production: a `.standard` store over a `CODEX_HOME` override.
    private func makeDefaultProvider(home: String, token: String, http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(["CODEX_HOME": home]),
                files: FakeFiles(["\(home)/auth.json": Self.auth(token: token, accountID: "acct-default")]),
                keychain: FakeKeychain()
            ),
            usageClient: CodexUsageClient(http: http)
        )
    }

    /// A managed-profile account card: a `.home`-scoped store over its registered home.
    private func makeCardProvider(cardID: String, home: String, token: String, http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(
            provider: CodexProvider.makeProvider(id: cardID, displayName: cardID),
            authStore: CodexAuthStore(
                environment: FakeEnvironment([:]),
                files: FakeFiles(["\(home)/auth.json": Self.auth(token: token, accountID: "acct-card")]),
                keychain: FakeKeychain(),
                scope: .home(path: home)
            ),
            usageClient: CodexUsageClient(http: http)
        )
    }

    func testRouterHandsEachCardItsOwnCredentialAndRefresh() async throws {
        let http = makeHTTP()
        let refreshes = Recorder()
        let router = CodexResetClaimRouter(
            providers: [
                makeDefaultProvider(home: "/tmp/codex-default", token: "token-default", http: http),
                makeCardProvider(cardID: "codex@ab12cd34", home: "/tmp/codex-work", token: "token-work", http: http),
            ],
            refreshAfterClaim: { cardID in refreshes.values.append(cardID) }
        )

        let defaultService = try XCTUnwrap(router.service(for: "codex"))
        let cardService = try XCTUnwrap(router.service(for: "codex@ab12cd34"))

        let defaultOutcome = await defaultService.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-default")
        let cardOutcome = await cardService.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-card")

        XCTAssertEqual(defaultOutcome, .success)
        XCTAssertEqual(cardOutcome, .success)
        let tokens = http.requests.compactMap { $0.headers["Authorization"] }
        XCTAssertEqual(
            Set(tokens),
            ["Bearer token-default", "Bearer token-work"],
            "each claim listed and consumed with its own card's credential"
        )
        XCTAssertEqual(
            http.requests.last?.headers["Authorization"],
            "Bearer token-work",
            "the account card's consume never falls back to the default card's login"
        )
        XCTAssertEqual(refreshes.values, ["codex", "codex@ab12cd34"],
                       "a successful claim refreshes the card it was tapped on")
    }

    func testUnknownCardHasNoService() {
        let http = makeHTTP()
        let router = CodexResetClaimRouter(
            providers: [makeDefaultProvider(home: "/tmp/codex-default", token: "token-default", http: http)],
            refreshAfterClaim: { _ in }
        )

        XCTAssertNil(router.service(for: "codex@ffffffff"))
        XCTAssertNotNil(router.service(for: "codex"), "the default card's service is always present")
    }

    /// A scoped card whose home has no usable login must fail the claim loudly — never fall back to
    /// the shared keychain item, which is another account's credential.
    func testScopedCardClaimNeverFallsBackToTheSharedKeychainItem() async throws {
        let keychain = ServiceKeychain(values: [
            CodexAuthStore.keychainService: Self.auth(token: "keychain-token", accountID: "acct-other"),
        ])
        let http = RoutingHTTPClient { _ in
            XCTFail("no request may be sent when the scoped home has no credential")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = CodexProvider(
            provider: CodexProvider.makeProvider(id: "codex@ab12cd34", displayName: "codex@ab12cd34"),
            authStore: CodexAuthStore(
                environment: FakeEnvironment([:]),
                files: FakeFiles([:]),
                keychain: keychain,
                scope: .home(path: "/tmp/codex-empty")
            ),
            usageClient: CodexUsageClient(http: http)
        )
        let router = CodexResetClaimRouter(providers: [provider], refreshAfterClaim: { _ in })

        let service = try XCTUnwrap(router.service(for: "codex@ab12cd34"))
        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "redeem-1")

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(http.requests.isEmpty)
    }
}
