import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetClaimBindingTests: XCTestCase {
    private nonisolated static let source = CodexAuthState.Source.file(path: "/fixture/auth.json")

    private nonisolated static func token(subject: String?, account: String?, version: Int = 1) throws -> String {
        var payload: [String: Any] = ["version": version]
        if let subject { payload["sub"] = subject }
        if let account { payload["https://api.openai.com/auth"] = ["chatgpt_account_id": account] }
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    private nonisolated static func state(
        subject: String = "user-A", account: String = "account-A", version: Int = 1,
        source: CodexAuthState.Source = source
    ) throws -> CodexAuthState {
        CodexAuthState(
            auth: CodexAuth(tokens: CodexTokens(
                accessToken: try token(subject: subject, account: account, version: version),
                refreshToken: "refresh-\(version)",
                idToken: try token(subject: subject, account: account, version: version),
                accountID: account
            )),
            source: source
        )
    }

    func testVerifiedIdentityAllowsTokenRotationAtTheSameSource() throws {
        let original = try Self.state()
        let rotated = try Self.state(version: 2)
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: original))

        XCTAssertNotEqual(original.auth.tokens?.accessToken, rotated.auth.tokens?.accessToken)
        XCTAssertTrue(binding.matches(rotated))
        XCTAssertEqual(binding.source, original.source)
    }

    func testVerifiedIdentityRejectsAnotherUserOrWorkspace() throws {
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: Self.state()))

        XCTAssertFalse(binding.matches(try Self.state(subject: "user-B")))
        XCTAssertFalse(binding.matches(try Self.state(account: "account-B")))
    }

    func testIdentityCannotMoveBetweenFilesKeychainAndAccountSnapshots() throws {
        let sources: [CodexAuthState.Source] = [
            Self.source, .file(path: "/other/auth.json"), .keychain,
            .accountSnapshot(profileID: "profile-A"), .accountSnapshot(profileID: "profile-B")
        ]
        for source in sources {
            let binding = try XCTUnwrap(CodexResetClaimBinding(authState: Self.state(source: source)))
            XCTAssertTrue(binding.matches(try Self.state(version: 2, source: source)))
            for other in sources where other != source {
                XCTAssertFalse(binding.matches(try Self.state(source: other)))
            }
        }
    }

    func testOpaqueCredentialAllowsOnlyTheSameTokenAndAccountHeader() throws {
        let original = CodexAuthState(
            auth: CodexAuth(tokens: CodexTokens(accessToken: "opaque-A", accountID: "account-A")),
            source: Self.source
        )
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: original))
        XCTAssertTrue(binding.matches(original))

        var changed = original
        changed.auth.tokens?.accessToken = "opaque-B"
        XCTAssertFalse(binding.matches(changed))
        changed = original
        changed.auth.tokens?.accountID = "account-B"
        XCTAssertFalse(binding.matches(changed))
        changed.auth.tokens?.accountID = nil
        XCTAssertFalse(binding.matches(changed))
    }

    func testOpaqueCredentialWithoutAccountHeaderRemainsBoundToThatAbsence() throws {
        let original = CodexAuthState(
            auth: CodexAuth(tokens: CodexTokens(accessToken: "opaque-A")), source: .keychain
        )
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: original))
        XCTAssertTrue(binding.matches(original))

        var changed = original
        changed.auth.tokens?.accountID = "account-A"
        XCTAssertFalse(binding.matches(changed))
    }

    func testConflictingSubjectsCannotCreateABindingOrMatchAnExistingOne() throws {
        let original = try Self.state()
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: original))
        var conflicting = original
        conflicting.auth.tokens?.idToken = try Self.token(subject: "user-B", account: "account-A")

        XCTAssertNil(CodexResetClaimBinding(authState: conflicting))
        XCTAssertFalse(binding.matches(conflicting))
    }

    func testConflictingAccountsAreRejectedEvenWithoutASubject() throws {
        let conflicts = [
            CodexTokens(
                accessToken: try Self.token(subject: "user-A", account: "account-B"),
                accountID: "account-A"
            ),
            CodexTokens(
                accessToken: try Self.token(subject: nil, account: "account-A"),
                idToken: try Self.token(subject: nil, account: "account-B"),
                accountID: "account-A"
            ),
            CodexTokens(
                accessToken: "opaque-A", idToken: try Self.token(subject: nil, account: "account-B"),
                accountID: "account-A"
            )
        ]
        for tokens in conflicts {
            XCTAssertNil(CodexResetClaimBinding(authState: .init(auth: CodexAuth(tokens: tokens), source: Self.source)))
        }
    }

    func testNoOAuthAccessTokenCannotCreateABinding() {
        for auth in [CodexAuth(), CodexAuth(tokens: CodexTokens(accessToken: "")), CodexAuth(apiKey: "api-only")] {
            XCTAssertNil(CodexResetClaimBinding(authState: .init(auth: auth, source: Self.source)))
        }
    }

    func testSnapshotSerializationPreservesQuotaStateWithoutPersistingTheClaimBinding() throws {
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let retryAfter = observedAt.addingTimeInterval(900)
        var snapshot = ProviderSnapshot(
            providerID: "codex", displayName: "Codex", lines: [],
            quotaObservedAt: observedAt, usageRetryAfter: retryAfter
        )
        snapshot.codexResetClaimBinding = try XCTUnwrap(CodexResetClaimBinding(authState: Self.state()))
        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decoded = try JSONDecoder().decode(ProviderSnapshot.self, from: data)

        XCTAssertNil(json["codexResetClaimBinding"])
        XCTAssertNil(decoded.codexResetClaimBinding)
        XCTAssertEqual(decoded.providerID, snapshot.providerID)
        XCTAssertEqual(decoded.quotaObservedAt, observedAt)
        XCTAssertEqual(decoded.usageRetryAfter, retryAfter)
        XCTAssertEqual(decoded.freshnessDate, observedAt)
    }

    func testClaimUsesRotatedCredentialAfterCreditFetchWithoutChangingTheAccount() async throws {
        let original = try Self.state()
        let rotated = try Self.state(version: 2)
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: original))
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(original.auth.tokens!.accessToken!)")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"credits":[{"id":"credit-A","expires_at":1800000000,"status":"available"}]}"#.utf8
                ))
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(rotated.auth.tokens!.accessToken!)")
            XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "account-A")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        var loads = 0
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { source in
                XCTAssertEqual(source, original.source)
                loads += 1
                return loads == 1 ? original : rotated
            }
        )

        let outcome = await service.claim(creditExpiringAt: expiry, redeemRequestID: "rotation", binding: binding)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
    }
}
