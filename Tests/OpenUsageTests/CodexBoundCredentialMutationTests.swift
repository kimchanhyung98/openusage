import XCTest
@testable import OpenUsage

@MainActor
final class CodexBoundCredentialMutationTests: XCTestCase {
    private let home = CodexBindingTestFixture.home + "/.codex"
    private var authPath: String { home + "/auth.json" }
    private var binding: CodexAccountBinding { .init(home: home, identityKey: "account-a") }

    func testChangedBoundIdentityRejectsDirectLoaderAndProviderBeforeHTTP() async {
        let original = CodexBindingTestFixture.auth(token: "token-a", accountID: "account-a")
        let replacement = CodexBindingTestFixture.auth(token: "token-b", accountID: "account-b")
        let files = CodexBindingFiles([authPath: original])
        let http = RoutingHTTPClient { request in
            XCTFail("Changed credentials must not reach HTTP: \(request.url)")
            return CodexBindingTestFixture.quota()
        }
        let provider = CodexBindingTestFixture.provider(files: files, binding: binding, http: http)
        files.set(replacement, at: authPath)

        XCTAssertThrowsError(try provider.authStore.loadAuthCandidates(allowInteraction: false)) { error in
            XCTAssertEqual(error as? CodexAuthError, .credentialsChanged)
        }
        XCTAssertFalse(CodexAuthError.credentialsChanged.allowsAuthFallback)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(files.savedPaths.isEmpty)
        XCTAssertEqual(files.text(at: authPath), replacement)
    }

    func testIdentityChangeDuringUsageRejectsSuccessfulQuota() async {
        let path = authPath
        let original = CodexBindingTestFixture.auth(token: "token-a", accountID: "account-a")
        let replacement = CodexBindingTestFixture.auth(token: "token-b", accountID: "account-b")
        let files = CodexBindingFiles([path: original])
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                XCTAssertEqual(request.headers["Authorization"], "Bearer token-a")
                XCTAssertEqual(request.headers["ChatGPT-Account-Id"], "account-a")
                files.set(replacement, at: path)
                return CodexBindingTestFixture.quota(used: 37)
            case CodexUsageClient.resetCreditsURL:
                return CodexBindingTestFixture.resetCredits
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CodexBindingTestFixture.provider(files: files, binding: binding, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.usageURL }.count, 1)
        XCTAssertTrue(http.requests.allSatisfy { $0.headers["ChatGPT-Account-Id"] == "account-a" })
        XCTAssertTrue(files.savedPaths.isEmpty)
        XCTAssertEqual(files.text(at: path), replacement)
    }

    func testSameIdentityTokenRotationDuringUsageAcceptsQuotaAndPreservesNewToken() async {
        let path = authPath
        let original = CodexBindingTestFixture.auth(token: "token-a", accountID: "account-a")
        let replacement = CodexBindingTestFixture.auth(token: "rotated-token-a", accountID: "account-a")
        let files = CodexBindingFiles([path: original])
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.usageURL:
                XCTAssertEqual(request.headers["Authorization"], "Bearer token-a")
                files.set(replacement, at: path)
                return CodexBindingTestFixture.quota(used: 37)
            case CodexUsageClient.resetCreditsURL:
                return CodexBindingTestFixture.resetCredits
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }
        let provider = CodexBindingTestFixture.provider(files: files, binding: binding, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("Expected quota from the same bound account")
        }
        XCTAssertEqual(used, 37)
        XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.usageURL }.count, 1)
        XCTAssertTrue(files.savedPaths.isEmpty)
        XCTAssertEqual(files.text(at: path), replacement)
    }

    func testProactiveLiveReloadRejectsDifferentAccountBeforeHTTP() async {
        let original = CodexBindingTestFixture.auth(
            token: CodexBindingTestFixture.jwt(accountID: "account-a", expiresIn: -60),
            accountID: "account-a", refreshToken: "refresh-a"
        )
        let replacement = CodexBindingTestFixture.auth(
            token: CodexBindingTestFixture.jwt(accountID: "account-b"), accountID: "account-b"
        )
        let files = CodexBindingFiles([authPath: original])
        files.queueReads([original, replacement], at: authPath)
        let http = RoutingHTTPClient { request in
            XCTFail("A different live account must not reach HTTP: \(request.url)")
            return CodexBindingTestFixture.quota()
        }
        let provider = CodexBindingTestFixture.provider(files: files, binding: binding, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertTrue(files.savedPaths.isEmpty)
        XCTAssertEqual(files.text(at: authPath), replacement)
    }

    func testForeignIDTokenInOAuthRefreshIsRejectedBeforeSaveOrQuota() async {
        let original = CodexBindingTestFixture.auth(
            token: CodexBindingTestFixture.jwt(accountID: "account-a", expiresIn: -60),
            accountID: "account-a", refreshToken: "refresh-a"
        )
        let foreignIDToken = CodexBindingTestFixture.jwt(accountID: "account-b")
        let files = CodexBindingFiles([authPath: original])
        let http = RoutingHTTPClient { request in
            guard request.url == CodexUsageClient.refreshURL else {
                XCTFail("A foreign refreshed identity must not reach quota: \(request.url)")
                return CodexBindingTestFixture.quota()
            }
            XCTAssertEqual(request.method, "POST")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"rotated-token-a","refresh_token":"rotated-refresh-a","id_token":"\#(foreignIDToken)"}"#.utf8
            ))
        }
        let provider = CodexBindingTestFixture.provider(files: files, binding: binding, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        XCTAssertTrue(files.savedPaths.isEmpty)
        XCTAssertEqual(files.text(at: authPath), original)
    }

    func testConflictingInitialAccessOrIDTokenClaimsRejectBeforeHTTP() async {
        let foreignToken = CodexBindingTestFixture.jwt(accountID: "account-b")
        let credentials = [
            CodexBindingTestFixture.auth(token: foreignToken, accountID: "account-a"),
            CodexBindingTestFixture.auth(token: "token-a", accountID: "account-a", idToken: foreignToken),
        ]

        for credential in credentials {
            let files = CodexBindingFiles([authPath: credential])
            let http = RoutingHTTPClient { request in
                XCTFail("Conflicting account claims must not reach HTTP: \(request.url)")
                return CodexBindingTestFixture.quota()
            }
            let provider = CodexBindingTestFixture.provider(files: files, binding: binding, http: http)

            let snapshot = await provider.refresh()

            XCTAssertEqual(snapshot.errorCategory, .other)
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertTrue(files.savedPaths.isEmpty)
            XCTAssertEqual(files.text(at: authPath), credential)
        }
    }
}
