import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetClaimApprovalTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let profileID = "reset-claim-approval"
    private nonisolated static let credential = #"{"tokens":{"access_token":"fixture-token","account_id":"account-A"}}"#

    private func binding() throws -> CodexResetClaimBinding {
        try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(
            auth: try XCTUnwrap(CodexAuthStore.parseAuth(Self.credential)),
            source: .accountSnapshot(profileID: Self.profileID)
        )))
    }

    private func makeService(
        keychain: ClaimApprovalKeychain,
        hasCredit: Bool = true,
        refreshAfterClaim: @escaping () async -> Void = {}
    ) -> (CodexResetClaimService, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                let body = hasCredit
                    ? """
                    {"credits":[{"id":"credit-target","status":"available","expires_at":\(Self.expiry.timeIntervalSince1970)}]}
                    """
                    : #"{"credits":[]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        return (CodexResetClaimService(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                scope: .accountSnapshot(profileID: Self.profileID)
            ),
            usageClient: CodexUsageClient(http: http), refreshAfterClaim: refreshAfterClaim
        ), http)
    }

    private func keychain(
        deniedReads: Set<Int> = [], deniedNoninteractiveReads: Set<Int> = []
    ) throws -> ClaimApprovalKeychain {
        let entry = AccountCredentialVault.Entry(credential: Self.credential, claudeOAuthAccount: nil)
        return ClaimApprovalKeychain(
            service: AccountCredentialVault.service(family: "codex", profileID: Self.profileID),
            value: String(decoding: try JSONEncoder().encode(entry), as: UTF8.self),
            deniedReads: deniedReads, deniedNoninteractiveReads: deniedNoninteractiveReads
        )
    }

    func testSuccessfulClaimOnlyAllowsApprovalForTheInitialCredentialRead() async throws {
        let keychain = try keychain()
        var refreshes = 0
        let (service, http) = makeService(keychain: keychain, refreshAfterClaim: { refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "success", binding: try binding()
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(keychain.interactionRequests, [true, false, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(refreshes, 1)
    }

    func testNoCreditRevalidatesWithoutRequestingAnotherApproval() async throws {
        let keychain = try keychain()
        var refreshes = 0
        let (service, http) = makeService(keychain: keychain, hasCredit: false, refreshAfterClaim: { refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "no-credit", binding: try binding()
        )

        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(keychain.interactionRequests, [true, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        XCTAssertEqual(refreshes, 1)
    }

    func testInitialApprovalFailureDoesNotSendRequests() async throws {
        let keychain = try keychain(deniedReads: [1])
        var refreshes = 0
        let (service, http) = makeService(keychain: keychain, refreshAfterClaim: { refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "denied", binding: try binding()
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(keychain.interactionRequests, [true])
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(refreshes, 0)
    }

    func testNoninteractiveReadFailureBeforeConsumeStopsTheClaim() async throws {
        let keychain = try keychain(deniedNoninteractiveReads: [2])
        var refreshes = 0
        let (service, http) = makeService(keychain: keychain, refreshAfterClaim: { refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "pre-consume", binding: try binding()
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(keychain.interactionRequests, [true, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        XCTAssertEqual(refreshes, 0)
    }

    func testNoninteractiveReadFailureAfterConsumePreservesSuccessAndSkipsRefresh() async throws {
        let keychain = try keychain(deniedNoninteractiveReads: [3])
        var refreshes = 0
        let (service, http) = makeService(keychain: keychain, refreshAfterClaim: { refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "post-consume", binding: try binding()
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(keychain.interactionRequests, [true, false, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(refreshes, 0)
    }

    func testExplicitRetryCanRequestApprovalAgainAndKeepsTheMatchedCredit() async throws {
        let keychain = try keychain(deniedNoninteractiveReads: [2])
        let (service, http) = makeService(keychain: keychain)
        let binding = try binding()
        let first = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: binding)

        let retry = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "retry", binding: binding)

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(retry, .success)
        XCTAssertEqual(keychain.interactionRequests, [true, false, true, false, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        let body = try XCTUnwrap(http.requests.last?.body)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload["credit_id"], "credit-target")
        XCTAssertEqual(payload["redeem_request_id"], "retry")
    }
}

private final class ClaimApprovalKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private let service: String
    private var value: String?
    private let deniedReads: Set<Int>
    private let deniedNoninteractiveReads: Set<Int>
    private var reads: [Bool] = []

    init(service: String, value: String, deniedReads: Set<Int>, deniedNoninteractiveReads: Set<Int>) {
        self.service = service
        self.value = value
        self.deniedReads = deniedReads
        self.deniedNoninteractiveReads = deniedNoninteractiveReads
    }

    var interactionRequests: [Bool] { lock.withLock { reads } }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        XCTAssertFalse(Thread.isMainThread, "Credential reads must not block the main thread")
        XCTAssertEqual(service, self.service)
        XCTAssertTrue(forCurrentUser)
        return try lock.withLock {
            reads.append(allowInteraction)
            if deniedReads.contains(reads.count)
                || (!allowInteraction && deniedNoninteractiveReads.contains(reads.count)) {
                throw KeychainError.readFailed("Saved account requires Keychain access.")
            }
            return value
        }
    }

    func readGenericPassword(service: String) throws -> String? { lock.withLock { value } }
    func writeGenericPassword(service: String, value: String) throws { lock.withLock { self.value = value } }
    func deleteGenericPassword(service: String) throws { lock.withLock { value = nil } }
}
