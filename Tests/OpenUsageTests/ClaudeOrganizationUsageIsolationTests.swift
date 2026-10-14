import os
import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeOrganizationUsageIsolationTests: XCTestCase {
    func testPrimaryFileLoginSeparatesOrganizationsAndPreservesSameOrganizationCooldown() async throws {
        try await assertOrganizationIsolation(source: .file)
    }

    func testPrimaryKeychainLoginSeparatesOrganizationsAndPreservesSameOrganizationCooldown() async throws {
        try await assertOrganizationIsolation(source: .keychain)
    }

    func testManagedSnapshotSeparatesOrganizationsAndPreservesSameOrganizationCooldown() async throws {
        try await assertOrganizationIsolation(source: .accountSnapshot)
    }

    func testAccountOnlyLoginsRejectAProfileFromAnotherAccount() async throws {
        for source in Source.allCases {
            let fixture = try credentials(source: source, token: "org-a-token")
            let http = RoutingHTTPClient { _ in
                Self.profile(account: "another-account", organization: "org-a")
            }
            let runtime = provider(fixture: fixture, http: http, store: isolatedClaudeUsageStore())

            let result = await runtime.refresh()

            assertIdentityUnavailable(result)
            XCTAssertNil(result.line(label: "Session"))
            XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
            assertUnchanged(fixture)
        }
    }

    func testMalformedFullIdentityIsRejectedBeforeProfileOrUsageRequests() async throws {
        let metadata = [
            #"{"accountUuid":"account-a|other","organizationUuid":"org-a"}"#,
            #"{"accountUuid":"account-a|"}"#,
            #"{"accountUuid":" ","organizationUuid":"org-a"}"#
        ]
        for source in Source.allCases {
            for accountMetadata in metadata {
                let fixture = try credentials(source: source, token: "org-a-token", accountMetadata: accountMetadata)
                let http = RoutingHTTPClient { _ in Self.profile(organization: "org-a") }
                let runtime = provider(fixture: fixture, http: http, store: isolatedClaudeUsageStore())

                let result = await runtime.refresh()

                assertIdentityUnavailable(result)
                XCTAssertNil(result.line(label: "Session"))
                XCTAssertTrue(http.requests.isEmpty)
                assertUnchanged(fixture)
            }
        }
    }

    private func assertOrganizationIsolation(source: Source) async throws {
        let store = isolatedClaudeUsageStore()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let orgAUsageCount = OSAllocatedUnfairLock(initialState: 0)
        let firstLogin = try credentials(source: source, token: "org-a-token")
        let otherOrganization = try credentials(source: source, token: "org-b-token")
        let rotatedLogin = try credentials(source: source, token: "org-a-rotated")
        let http = RoutingHTTPClient { request in
            let isOrgB = request.headers["Authorization"] == "Bearer org-b-token"
            if request.url.path.hasSuffix("/profile") {
                return Self.profile(organization: isOrgB ? "org-b" : "org-a")
            }
            if isOrgB { return Self.usage(77) }
            let attempt = orgAUsageCount.withLock { $0 += 1; return $0 }
            return attempt == 2
                ? HTTPResponse(statusCode: 429, headers: [:], body: Data())
                : Self.usage(42)
        }
        func refresh(_ fixture: CredentialFixture) async -> ProviderSnapshot {
            await provider(fixture: fixture, http: http, store: store, now: { clock.withLock { $0 } }).refresh()
        }

        let first = await refresh(firstLogin)
        XCTAssertEqual(first.quotaObservedAt, start)
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await refresh(firstLogin)
        XCTAssertEqual(limited.usageRetryAfter, start.addingTimeInterval(901))
        clock.withLock { $0 = start.addingTimeInterval(2) }
        let other = await refresh(otherOrganization)

        XCTAssertEqual(other.line(label: "Session"), Self.session(77))
        XCTAssertNil(other.usageRetryAfter)
        XCTAssertEqual(other.quotaObservedAt, start.addingTimeInterval(2))
        XCTAssertEqual(http.requests.filter {
            $0.url.path.hasSuffix("/usage") && $0.headers["Authorization"] == "Bearer org-b-token"
        }.count, 1)

        clock.withLock { $0 = start.addingTimeInterval(3) }
        let returned = await refresh(rotatedLogin)

        XCTAssertEqual(returned.line(label: "Session"), Self.session(42))
        XCTAssertEqual(returned.usageRetryAfter, limited.usageRetryAfter)
        XCTAssertEqual(returned.quotaObservedAt, start)
        XCTAssertNil(returned.liveQuotaObservedAt)
        XCTAssertEqual(orgAUsageCount.withLock { $0 }, 2)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/profile") }.count, 4)
        for fixture in [firstLogin, otherOrganization, rotatedLogin] {
            assertUnchanged(fixture)
            XCTAssertEqual(fixture.authStore.loadCredentialSet().candidates.first?.accountIdentityKey, "account-a")
        }
    }

    private enum Source: CaseIterable {
        case file, keychain, accountSnapshot
    }

    private struct CredentialFixture {
        let authStore: ClaudeAuthStore
        let files: FakeFiles
        let keychain: ServiceKeychain
        let originalFiles: [String: String]
        let originalKeychain: [String: String]
    }

    private func credentials(
        source: Source,
        token: String,
        accountMetadata: String = #"{"accountUuid":"account-a"}"#
    ) throws -> CredentialFixture {
        let home = token == "org-b-token" ? "/tmp/claude-org-b" : "/tmp/claude-org-a"
        let files = FakeFiles()
        let keychain = ServiceKeychain()
        let credential = #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": home])
        let authStore: ClaudeAuthStore
        switch source {
        case .file, .keychain:
            files.files["\(home)/.claude.json"] = #"{"oauthAccount":\#(accountMetadata)}"#
            authStore = ClaudeAuthStore(
                environment: environment, files: files, keychain: keychain, allowsDesktopFallback: false
            )
            if source == .file {
                files.files["\(home)/.credentials.json"] = credential
            } else {
                keychain.currentUserValues[authStore.keychainServiceCandidates().first!] = credential
            }
        case .accountSnapshot:
            let profile = AccountProfile(
                id: token == "org-b-token" ? "saved-org-b" : "saved-org-a",
                family: "claude", label: "Saved Account", identityKey: "account-a", createdAt: .distantPast
            )
            let entry = AccountCredentialVault.Entry(credential: credential, claudeOAuthAccount: accountMetadata)
            try AccountCredentialVault(keychain: keychain).save(entry, profile: profile)
            authStore = ClaudeAuthStore(
                environment: environment, files: files, keychain: keychain,
                scope: .accountSnapshot(profileID: profile.id)
            )
        }
        return CredentialFixture(
            authStore: authStore, files: files, keychain: keychain,
            originalFiles: files.files, originalKeychain: keychain.currentUserValues
        )
    }

    private func provider(
        fixture: CredentialFixture, http: HTTPClient, store: ClaudeUsageStateStore,
        now: @escaping @Sendable () -> Date = Date.init
    ) -> ClaudeProvider {
        ClaudeProvider(
            authStore: fixture.authStore, usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: store,
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), includePiUsage: false,
            now: now, pricing: { TestPricing.bundled }
        )
    }

    private func assertIdentityUnavailable(_ snapshot: ProviderSnapshot) {
        guard case .badge(_, let message, _, _)? = snapshot.line(label: "Error") else {
            return XCTFail("Expected an account identity error")
        }
        XCTAssertEqual(message, ClaudeUsageStateStore.StoreError.identityUnavailable.localizedDescription)
    }

    private func assertUnchanged(_ fixture: CredentialFixture) {
        XCTAssertEqual(fixture.files.files, fixture.originalFiles)
        XCTAssertEqual(fixture.keychain.currentUserValues, fixture.originalKeychain)
        XCTAssertTrue(fixture.keychain.values.isEmpty)
    }

    private nonisolated static func profile(account: String = "account-a", organization: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"account":{"uuid":"\#(account)"},"organization":{"uuid":"\#(organization)"}}"#.utf8
        ))
    }

    private nonisolated static func usage(_ percent: Int) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"five_hour":{"utilization":\#(percent)}}"#.utf8
        ))
    }

    private static func session(_ percent: Double) -> MetricLine {
        .progress(label: "Session", used: percent, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs)
    }
}
