import XCTest
@testable import OpenUsage

@MainActor
final class CodexManagedRefreshPreservationTests: XCTestCase {
    func testAccountSwitchPreservesRotatedTokensInDepartedSnapshot() async throws {
        let fixture = try ManagedRefreshFixture()
        defer { fixture.remove() }
        let http = ManagedRefreshHTTP { try fixture.switchToB() }
        let provider = makeProvider(fixture: fixture, http: http)

        let result = await provider.refresh()

        XCTAssertNotNil(result.errorCategory)
        XCTAssertNil(result.authenticationIssue)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        try assertSharedBUnchanged(fixture)
        try assertRotatedSnapshot(fixture)
    }

    func testUnauthorizedRetryPreservesRotatedTokensAfterAccountSwitch() async throws {
        let fixture = try ManagedRefreshFixture(freshToken: true)
        defer { fixture.remove() }
        let http = ManagedRefreshHTTP(rejectFirstUsage: true) { try fixture.switchToB() }
        let provider = makeProvider(fixture: fixture, http: http)

        let result = await provider.refresh()

        XCTAssertNotNil(result.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL, CodexUsageClient.refreshURL])
        try assertSharedBUnchanged(fixture)
        try assertRotatedSnapshot(fixture)
    }

    func testAccountSwitchDoesNotOverwriteAChangedDepartedSnapshot() async throws {
        for change in ["new-login", "unknown-field", "formatting"] {
            let fixture = try ManagedRefreshFixture()
            defer { fixture.remove() }
            let changed: String
            switch change {
            case "new-login":
                changed = fixture.original.replacingOccurrences(of: "old-a", with: "new-login-a")
            case "unknown-field":
                changed = fixture.original.replacingOccurrences(of: "true", with: "false")
            default:
                changed = fixture.original + "\n"
            }
            let replacement = AccountCredentialVault.Entry(credential: changed, claudeOAuthAccount: nil)
            let http = ManagedRefreshHTTP {
                try fixture.switchToB()
                try fixture.vault.save(replacement, profile: fixture.profileA)
            }
            let provider = makeProvider(fixture: fixture, http: http)

            let result = await provider.refresh()

            XCTAssertNotNil(result.errorCategory, change)
            XCTAssertEqual(try fixture.vault.load(profile: fixture.profileA), replacement, change)
            XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL], change)
            try assertSharedBUnchanged(fixture)
        }
    }

    func testAccountSwitchDoesNotRecreateADeletedDepartedSnapshot() async throws {
        let fixture = try ManagedRefreshFixture()
        defer { fixture.remove() }
        let http = ManagedRefreshHTTP {
            try fixture.switchToB()
            try fixture.vault.delete(profile: fixture.profileA)
        }
        let provider = makeProvider(fixture: fixture, http: http)

        let result = await provider.refresh()

        XCTAssertNotNil(result.errorCategory)
        XCTAssertNil(try fixture.vault.load(profile: fixture.profileA))
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        try assertSharedBUnchanged(fixture)
    }

    func testUnboundRuntimeLeavesSnapshotsUntouchedAfterAccountSwitch() async throws {
        let fixture = try ManagedRefreshFixture()
        defer { fixture.remove() }
        let http = ManagedRefreshHTTP { try fixture.switchToB() }
        let provider = makeProvider(fixture: fixture, http: http, bindsSnapshot: false)

        let result = await provider.refresh()

        XCTAssertNotNil(result.errorCategory)
        XCTAssertEqual(try fixture.vault.load(profile: fixture.profileA)?.credential, fixture.original)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        try assertSharedBUnchanged(fixture)
    }

    func testWeeklyTimerPreservesDepartedSnapshotAndRejectsChangedSharedSource() async throws {
        let fixture = try ManagedRefreshFixture()
        defer { fixture.remove() }
        let http = ManagedRefreshHTTP { try fixture.switchToB() }
        let provider = makeProvider(fixture: fixture, http: http)
        let original = try XCTUnwrap(CodexAuthStore.parseAuth(fixture.original))
        let accountKey = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: original))

        do {
            _ = try await provider.prepareWeeklyTimerSession(expectedAccountKey: accountKey)
            XCTFail("The weekly timer must reject the changed shared authentication")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
        }

        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        try assertSharedBUnchanged(fixture)
        try assertRotatedSnapshot(fixture)
    }

    private func makeProvider(
        fixture: ManagedRefreshFixture, http: ManagedRefreshHTTP, bindsSnapshot: Bool = true
    ) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: LocalTextFileAccessor(), keychain: fixture.keychain,
                scope: .home(path: fixture.codexHome.path),
                managedSnapshotProfileID: bindsSnapshot ? fixture.profileA.id : nil
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(
                environment: FakeEnvironment(), cacheIdentityOverride: "managed-refresh", rootsOverride: []
            ),
            includePiUsage: false, pricing: { .empty }
        )
    }

    private func assertSharedBUnchanged(
        _ fixture: ManagedRefreshFixture, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try String(contentsOf: fixture.authFile, encoding: .utf8), fixture.replacement,
            file: file, line: line
        )
        XCTAssertEqual(
            try fixture.vault.load(profile: fixture.profileB)?.credential, fixture.replacement,
            file: file, line: line
        )
    }

    private func assertRotatedSnapshot(
        _ fixture: ManagedRefreshFixture, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let saved = try XCTUnwrap(fixture.vault.load(profile: fixture.profileA), file: file, line: line)
        let auth = try XCTUnwrap(CodexAuthStore.parseAuth(saved.credential), file: file, line: line)
        XCTAssertEqual(auth.tokens?.accessToken, "rotated-a", file: file, line: line)
        XCTAssertEqual(auth.tokens?.refreshToken, "rotated-refresh-a", file: file, line: line)
        XCTAssertEqual(auth.tokens?.accountID, "account-a", file: file, line: line)
        let document = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(saved.credential), file: file, line: line)
        XCTAssertEqual(document["auth_mode"] as? String, "chatgpt", file: file, line: line)
        XCTAssertEqual(document["root_sentinel"] as? [String: Bool], ["keep": true], file: file, line: line)
        let tokens = try XCTUnwrap(document["tokens"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(tokens["token_sentinel"] as? [Int], [1, 2], file: file, line: line)
    }
}

private struct ManagedRefreshFixture: Sendable {
    let home: URL
    let keychain = ServiceKeychain()
    let profileA = AccountProfile(
        id: "profile-a", family: "codex", label: "A", identityKey: "account-a", createdAt: .distantPast
    )
    let profileB = AccountProfile(
        id: "profile-b", family: "codex", label: "B", identityKey: "account-b", createdAt: .distantPast
    )
    let original: String
    let replacement = #"{"tokens":{"access_token":"account-b","refresh_token":"refresh-b","account_id":"account-b"}}"#

    var codexHome: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    var authFile: URL { codexHome.appendingPathComponent("auth.json") }
    var vault: AccountCredentialVault { AccountCredentialVault(keychain: keychain) }

    init(freshToken: Bool = false) throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.ManagedRefresh.\(UUID().uuidString)", isDirectory: true)
        let refreshedAt = freshToken ? OpenUsageISO8601.string(from: Date()) : "2020-01-01T00:00:00Z"
        original = #"{"auth_mode":"chatgpt","root_sentinel":{"keep":true},"tokens":{"access_token":"old-a","refresh_token":"refresh-a","id_token":"e30.eyJzdWIiOiJ1c2VyLWEifQ.sig","account_id":"account-a","token_sentinel":[1,2]},"last_refresh":"\#(refreshedAt)"}"#
        try LocalTextFileAccessor().writeText(authFile.path, original)
        try vault.save(.init(credential: original, claudeOAuthAccount: nil), profile: profileA)
        try vault.save(.init(credential: replacement, claudeOAuthAccount: nil), profile: profileB)
    }

    func switchToB() throws {
        let switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        )
        try switcher.switchAuthentication(to: profileB, from: profileA)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }
}

private final class ManagedRefreshHTTP: HTTPClient, @unchecked Sendable {
    let onRefresh: @Sendable () throws -> Void
    let rejectFirstUsage: Bool
    var requests: [HTTPRequest] = []

    init(rejectFirstUsage: Bool = false, onRefresh: @escaping @Sendable () throws -> Void) {
        self.rejectFirstUsage = rejectFirstUsage
        self.onRefresh = onRefresh
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if rejectFirstUsage, requests.count == 1 {
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        if request.url == CodexUsageClient.refreshURL {
            try onRefresh()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"rotated-a","refresh_token":"rotated-refresh-a"}"#.utf8
            ))
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#.utf8
        ))
    }
}
