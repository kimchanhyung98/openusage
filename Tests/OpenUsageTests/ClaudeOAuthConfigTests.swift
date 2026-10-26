import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeOAuthConfigTests: XCTestCase {
    func testProductionAndStagingKeepHTTPSAndClientOverrides() throws {
        let production = try store().oauthConfig()
        XCTAssertEqual(production.usageURL.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(production.refreshURL.absoluteString, "https://platform.claude.com/v1/oauth/token")

        let staging = try store([
            "USER_TYPE": "ant", "USE_STAGING_OAUTH": "1", "CLAUDE_CODE_OAUTH_CLIENT_ID": "fixture-client"
        ]).oauthConfig()
        XCTAssertEqual(staging.usageURL.absoluteString, "https://api-staging.anthropic.com/api/oauth/usage")
        XCTAssertEqual(staging.refreshURL.absoluteString, "https://platform.staging.ant.dev/v1/oauth/token")
        XCTAssertEqual(staging.clientID, "fixture-client")
    }

    func testCustomHTTPSKeepsPathAndOverridesLocalBase() throws {
        let auth = store([
            "USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1",
            "CLAUDE_LOCAL_OAUTH_API_BASE": "http://remote.example",
            "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://custom.example/prefix/"
        ])
        let config = try auth.oauthConfig()

        XCTAssertEqual(config.usageURL.absoluteString, "https://custom.example/prefix/api/oauth/usage")
        XCTAssertEqual(config.refreshURL.absoluteString, "https://custom.example/prefix/v1/oauth/token")
        XCTAssertEqual(auth.keychainServiceCandidates(), ["Claude Code-custom-oauth-credentials"])
    }

    func testLocalDevelopmentDefaultKeepsLoopbackHTTP() throws {
        let auth = store(["USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1"])
        let config = try auth.oauthConfig()

        XCTAssertEqual(config.usageURL.absoluteString, "http://localhost:8000/api/oauth/usage")
        XCTAssertEqual(config.refreshURL.absoluteString, "http://localhost:8000/v1/oauth/token")
        XCTAssertEqual(auth.keychainServiceCandidates(), ["Claude Code-local-oauth-credentials"])
    }

    func testExplicitLoopbackHostsAllowHTTP() throws {
        for base in ["http://localhost:8000", "HTTP://LOCALHOST:8000", "http://127.0.0.1:8000", "http://[::1]:8000"] {
            for environment in endpointEnvironments(base) {
                let config = try store(environment).oauthConfig()
                XCTAssertEqual(config.usageURL.absoluteString, "\(base)/api/oauth/usage")
                XCTAssertEqual(config.refreshURL.absoluteString, "\(base)/v1/oauth/token")
            }
        }
    }

    func testUnsafeEndpointsFailWithoutProductionFallback() {
        let bases = [
            "http://remote.example", "http://192.168.1.20:8000",
            "http://localhost.remote.example", "http://127.0.0.1.remote.example",
            "http://localhost@remote.example", "http://[::ffff:192.168.1.20]",
            "http://localhost.", "http://127.1", "http://2130706433",
            "http://fixture-secret:fixture-secret@remote.example/fixture-secret?fixture-secret#fixture-secret",
            "ftp://localhost", "file:///tmp/oauth", "/relative/oauth", "https:///missing-host"
        ]
        for base in bases {
            for environment in endpointEnvironments(base) {
                let auth = store(environment)
                XCTAssertThrowsError(try auth.oauthConfig(), base) { error in
                    guard case ClaudeAuthError.invalidOAuthURL = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
                }
                XCTAssertEqual(auth.keychainServiceCandidates().count, 1)
            }
        }
    }

    func testProviderRejectsRemoteHTTPBeforeSendingAnyCredentials() async {
        for environment in endpointEnvironments("http://remote.example") {
            for (expiresAt, hasIdentity) in [(4_102_444_800_000, true), (1, true), (1, false)] {
                var fixtureFiles = [
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":\#(expiresAt),"scopes":["user:profile"]}}"#
                ]
                if hasIdentity { fixtureFiles["/tmp/claude/.claude.json"] = claudeUsageTestIdentity() }
                let files = FakeFiles(fixtureFiles)
                let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
                let auth = ClaudeAuthStore(
                    environment: FakeEnvironment(environment.merging(["CLAUDE_CONFIG_DIR": "/tmp/claude"]) { _, value in value }),
                    files: files, keychain: FakeKeychain(), allowsDesktopFallback: false
                )
                let provider = ClaudeProvider(
                    authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                    usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                    includePiUsage: false, pricing: { TestPricing.bundled }
                )

                let result = await provider.refresh()

                XCTAssertTrue(http.requests.isEmpty)
                XCTAssertFalse(result.lines.isEmpty)
                XCTAssertTrue(result.lines.allSatisfy(\.isError))
                XCTAssertEqual(files.files, fixtureFiles)
            }
        }
    }

    private func store(_ environment: [String: String] = [:]) -> ClaudeAuthStore {
        ClaudeAuthStore(environment: FakeEnvironment(environment), files: FakeFiles(), keychain: FakeKeychain())
    }

    private func endpointEnvironments(_ base: String) -> [[String: String]] {
        [
            ["CLAUDE_CODE_CUSTOM_OAUTH_URL": base],
            ["USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1", "CLAUDE_LOCAL_OAUTH_API_BASE": base]
        ]
    }
}
