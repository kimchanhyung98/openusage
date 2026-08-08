import XCTest
@testable import OpenUsage

@MainActor
final class CodexAccountIsolationTests: XCTestCase {
    private func auth(token: String, accountID: String = "acct-1") -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }

    private func scopedStore(
        home: String,
        files: FakeFiles,
        keychain: any KeychainAccessing = FakeKeychain(),
        environment: FakeEnvironment = FakeEnvironment([:])
    ) -> CodexAuthStore {
        CodexAuthStore(environment: environment, files: files, keychain: keychain, scope: .home(path: home))
    }

    func testScopedStoreReadsOnlyItsOwnAuthFile() {
        let files = FakeFiles([
            "/tmp/codex-a/auth.json": auth(token: "token-a"),
            "/tmp/codex-b/auth.json": auth(token: "token-b"),
        ])
        let storeA = scopedStore(home: "/tmp/codex-a", files: files)
        let storeB = scopedStore(home: "/tmp/codex-b", files: files)

        XCTAssertEqual(storeA.authPaths(), ["/tmp/codex-a/auth.json"])
        XCTAssertEqual(storeB.authPaths(), ["/tmp/codex-b/auth.json"])
        XCTAssertEqual(storeA.loadAuthCandidates().first?.auth.tokens?.accessToken, "token-a")
        XCTAssertEqual(storeB.loadAuthCandidates().first?.auth.tokens?.accessToken, "token-b",
                       "two scoped stores can never see each other's credentials")
    }

    func testScopedStoreIgnoresCodexHomeEnvAndDefaultHomes() {
        let files = FakeFiles([
            "/tmp/codex-env/auth.json": auth(token: "env-token"),
            // `authPaths()`가 만드는 표준 해석의 tilde 리터럴 경로와 동일
            "~/.config/codex/auth.json": auth(token: "default-token"),
            "~/.codex/auth.json": auth(token: "default-token"),
            "/tmp/codex-a/auth.json": auth(token: "token-a"),
        ])
        let store = scopedStore(
            home: "/tmp/codex-a",
            files: files,
            environment: FakeEnvironment(["CODEX_HOME": "/tmp/codex-env"])
        )

        XCTAssertEqual(store.authPaths(), ["/tmp/codex-a/auth.json"])
        XCTAssertEqual(
            store.loadAuthCandidates().compactMap { $0.auth.tokens?.accessToken },
            ["token-a"],
            "neither the env override nor a default home may leak into a scoped card"
        )
    }

    func testScopedStoreNeverReadsTheSharedKeychainItem() {
        let keychain = ServiceKeychain(values: [
            CodexAuthStore.keychainService: auth(token: "keychain-token"),
        ])
        let store = scopedStore(home: "/tmp/codex-a", files: FakeFiles([:]), keychain: keychain)

        XCTAssertNil(store.loadKeychainAuth(),
                     "a scoped card must not even probe the shared item — the read alone can prompt")
        XCTAssertTrue(store.loadAuthCandidates().isEmpty)
    }

    func testStandardStoreKeepsTheKeychainFallback() {
        let keychain = ServiceKeychain(values: [
            CodexAuthStore.keychainService: auth(token: "keychain-token"),
        ])
        let store = CodexAuthStore(environment: FakeEnvironment([:]), files: FakeFiles([:]), keychain: keychain)

        XCTAssertEqual(store.loadKeychainAuth()?.auth.tokens?.accessToken, "keychain-token")
    }

    func testScopedProviderCredentialFootprintIsLimitedToItsHome() async {
        let keychain = ServiceKeychain(values: [
            CodexAuthStore.keychainService: auth(token: "keychain-token"),
        ])
        let files = FakeFiles(["/tmp/codex-b/auth.json": auth(token: "token-b")])
        let provider = CodexProvider(
            authStore: scopedStore(home: "/tmp/codex-a", files: files, keychain: keychain)
        )

        let empty = await provider.hasLocalCredentials()
        XCTAssertFalse(empty, "keychain + another home must not seed the scoped card on")

        files.files["/tmp/codex-a/auth.json"] = auth(token: "token-a")
        let present = await provider.hasLocalCredentials()
        XCTAssertTrue(present)
    }

    func testScopedProviderRefreshAuthenticatesWithItsOwnCredential() async {
        let keychain = ServiceKeychain(values: [
            CodexAuthStore.keychainService: auth(token: "keychain-token"),
        ])
        let files = FakeFiles(["/tmp/codex-a/auth.json": auth(token: "token-a")])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL {
                XCTAssertEqual(request.headers["Authorization"], "Bearer token-a")
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data("""
                    {"rate_limit": {"primary_window": {
                        "used_percent": 25, "limit_window_seconds": 18000,
                        "reset_after_seconds": 18000, "reset_at": \(Int(now.timeIntervalSince1970) + 18000)
                    }}}
                    """.utf8)
                )
            }
            // best-effort reset-credit fetch 실패는 refresh에 영향 없음
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CodexProvider(
            authStore: scopedStore(home: "/tmp/codex-a", files: files, keychain: keychain),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter, got \(snapshot.lines)")
        }
        XCTAssertEqual(used, 25)
        let usageRequests = http.requests.filter { $0.url == CodexUsageClient.usageURL }
        XCTAssertEqual(usageRequests.count, 1)
    }

    func testScopedSaveWritesBackToTheSameFile() throws {
        let keychain = ServiceKeychain(values: [
            CodexAuthStore.keychainService: auth(token: "keychain-token"),
        ])
        let files = FakeFiles(["/tmp/codex-a/auth.json": auth(token: "token-a")])
        let store = scopedStore(home: "/tmp/codex-a", files: files, keychain: keychain)
        let state = try XCTUnwrap(store.loadAuthCandidates().first)

        var rotated = state.auth
        rotated.tokens?.accessToken = "token-a-rotated"
        try store.save(CodexAuthState(auth: rotated, source: state.source))

        XCTAssertEqual(
            CodexAuthStore.parseAuth(files.files["/tmp/codex-a/auth.json"] ?? "")?.tokens?.accessToken,
            "token-a-rotated",
            "the rotated token must land in the scoped home's own auth.json"
        )
        XCTAssertEqual(
            keychain.values[CodexAuthStore.keychainService],
            auth(token: "keychain-token"),
            "a scoped card never writes the shared keychain item"
        )
    }
}
