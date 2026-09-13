import CommonCrypto
import CryptoKit
import Foundation
import XCTest
@testable import OpenUsage

final class ClaudeDesktopAuthStoreTests: XCTestCase {
    let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
    let organization = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    let otherOrganization = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    let clientID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    let otherClientID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let password = "fixture-safe-storage-password"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testDecryptsElectronSafeStorageValue() throws {
        let key = try ClaudeDesktopAuthStore.deriveKey(password: password)
        let plaintext = Data(#"{"token":"secret"}"#.utf8)
        let encrypted = try encrypt(plaintext, key: key)

        XCTAssertEqual(try ClaudeDesktopAuthStore.decrypt(encrypted, key: key), plaintext)
        XCTAssertThrowsError(try ClaudeDesktopAuthStore.decrypt(Data("v11bad".utf8), key: key))
    }

    func testSelectsActiveOrganizationFromV2Cache() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600),
                cacheKey(organization: otherOrganization): tokenEntry("other-token", expiresIn: 7_200)
            ],
            v1: [
                cacheKey(organization: organization): tokenEntry("old-token", expiresIn: 10_800)
            ]
        )

        let result = fixture.store.load(allowInteraction: false)

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.oauth?.accessToken, "desktop-token")
        XCTAssertNil(result.oauth?.refreshToken)
        XCTAssertEqual(result.oauth?.scopes, ["user:profile", "user:inference"])
    }

    func testV1FallbackDoesNotOverrideTombstonedV2Key() throws {
        let key = cacheKey(organization: organization)
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [key: NSNull()],
            v1: [key: tokenEntry("resurrected-token", expiresIn: 3_600)],
            now: now
        )

        guard case .notFound = selection else {
            return XCTFail("V2 tombstone should suppress the matching V1 token")
        }
    }

    func testLoadsAccountPrefixedDesktopCacheForActiveOwner() throws {
        let account = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let fixture = try makeFixture(
            activeOrganization: organization,
            activeAccountUUID: account,
            v2: ["acct:\(account)|\(cacheKey(organization: organization))": tokenEntry("scoped-token", expiresIn: 3_600)]
        )

        let result = fixture.store.load(allowInteraction: false)

        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.oauth?.accessToken, "scoped-token")
        XCTAssertNil(result.oauth?.refreshToken)
    }

    func testAccountMetadataAndScopedCacheReloadTogetherAfterDesktopSwitch() throws {
        let account = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let replacement = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let caches = [
            "acct:\(account)|\(cacheKey(organization: organization))": tokenEntry("previous-owner", expiresIn: 7_200),
            "acct:\(replacement)|\(cacheKey(organization: organization))": tokenEntry("current-owner", expiresIn: 3_600)
        ]
        let fixture = try makeFixture(activeOrganization: organization, activeAccountUUID: account, v2: caches)
        XCTAssertEqual(fixture.store.load(allowInteraction: false).oauth?.accessToken, "previous-owner")

        let replacementFixture = try makeFixture(activeOrganization: organization, activeAccountUUID: replacement, v2: caches)
        fixture.files.files = replacementFixture.files.files

        XCTAssertEqual(fixture.store.load(allowInteraction: false).oauth?.accessToken, "current-owner")
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    func testInvalidDesktopAccountMetadataKeepsOnlyLegacyFallback() throws {
        let account = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        for metadata: String? in [nil, "", "not-a-uuid"] {
            let fixture = try makeFixture(
                activeOrganization: organization,
                activeAccountUUID: metadata,
                v2: ["acct:\(account)|\(cacheKey(organization: organization))": tokenEntry("unverified-owner", expiresIn: 7_200)],
                v1: [cacheKey(organization: organization): tokenEntry("legacy-token", expiresIn: 3_600)]
            )

            XCTAssertEqual(fixture.store.load(allowInteraction: false).oauth?.accessToken, "legacy-token")
        }
    }

    func testScopedDesktopCacheRespectsCredentialScopeAndFallbackGate() throws {
        let account = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        let cases: [(ClaudeCredentialScope, Bool)] = [
            (.standard, false),
            (.configDir(path: "/empty-home", keychainLiteral: "/empty-home"), true),
            (.accountSnapshot(profileID: "inactive"), true)
        ]
        for (scope, allowsDesktopFallback) in cases {
            let fixture = try makeFixture(
                activeOrganization: organization,
                activeAccountUUID: account,
                v2: ["acct:\(account)|\(cacheKey(organization: organization))": tokenEntry("desktop-token", expiresIn: 3_600)]
            )
            let authStore = ClaudeAuthStore(
                environment: FakeEnvironment([:]), files: fixture.files, keychain: FakeKeychain(nil),
                desktop: fixture.store, scope: scope, allowsDesktopFallback: allowsDesktopFallback
            )

            let load = authStore.loadCredentialSet(forceDesktopFallback: true)

            XCTAssertEqual(load.desktopStatus, .notFound)
            XCTAssertFalse(load.candidates.contains { $0.source == .desktop })
            XCTAssertTrue(fixture.keyReader.calls.isEmpty)
        }
    }

    func testFullScopeProductionClientOutranksLongerLivedProfileOnlyEntry() throws {
        // 동일 org의 장수명 profile-only stale 5x vs 만료 임박한 full-scope production 20x — expiry만으로는 오선택
        let productionClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization, scopes: "user:profile"):
                    tokenEntry("stale-5x-token", expiresIn: 86_400, rateLimitTier: "default_claude_max_5x"),
                cacheKey(
                    organization: organization,
                    clientID: productionClientID,
                    scopes: "user:profile user:inference"
                ):
                    tokenEntry("current-20x-token", expiresIn: 1_800, rateLimitTier: "default_claude_max_20x")
            ],
            v1: nil,
            now: now
        )

        guard case .available(let oauth) = selection else {
            return XCTFail("expected an available credential, got \(selection)")
        }
        XCTAssertEqual(oauth.accessToken, "current-20x-token")
        XCTAssertEqual(oauth.rateLimitTier, "default_claude_max_20x")
    }

    func testFullScopeEntryOutranksProfileOnlyEntryForNonProductionClients() throws {
        let selection = ClaudeDesktopAuthStore.selectCredential(
            activeOrganization: organization,
            v2: [
                cacheKey(organization: organization, scopes: "user:profile"):
                    tokenEntry("profile-only-token", expiresIn: 86_400),
                cacheKey(organization: organization, clientID: otherClientID, scopes: "user:profile user:inference"):
                    tokenEntry("full-scope-token", expiresIn: 1_800)
            ],
            v1: nil,
            now: now
        )

        guard case .available(let oauth) = selection else {
            return XCTFail("expected an available credential, got \(selection)")
        }
        XCTAssertEqual(oauth.accessToken, "full-scope-token")
    }

    func testBackgroundReadDoesNotPromptButManualReadCan() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            requiresInteraction: true
        )

        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .permissionRequired)
        XCTAssertEqual(fixture.keyReader.calls, [false])
        XCTAssertEqual(fixture.store.load(allowInteraction: true).status, .available)
        XCTAssertEqual(fixture.keyReader.calls, [false, true])

        // 승인 후 derived key가 캐시되어 이후 background refresh는 prompt 없음
        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .available)
        XCTAssertEqual(fixture.keyReader.calls, [false, true])
    }

    func testExpiredDesktopTokenIsStale() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired", expiresIn: -1)]
        )

        XCTAssertEqual(fixture.store.load(allowInteraction: false).status, .stale)
    }

    func testWorkingCLICredentialsSkipDesktopProbe() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: fixture.files,
            keychain: FakeKeychain(
                #"{"claudeAiOauth":{"accessToken":"cli-token","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            ),
            desktop: fixture.store,
            now: { now }
        )

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "cli-token")
        XCTAssertEqual(load.desktopStatus, .notChecked)
        XCTAssertTrue(fixture.keyReader.calls.isEmpty)
    }

    func testWhitespaceOnlyCLIEntryDoesNotBlockDesktop() throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
            files: fixture.files,
            keychain: FakeKeychain(
                #"{"claudeAiOauth":{"accessToken":"   ","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            ),
            desktop: fixture.store,
            now: { now }
        )

        let load = authStore.loadCredentialSet()

        XCTAssertEqual(load.candidates.first?.source, .desktop)
        XCTAssertEqual(load.candidates.first?.oauth.accessToken, "desktop-token")
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    @MainActor
    func testDesktopPermissionIsNotMaskedByScopedCLIToken() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
            requiresInteraction: true
        )
        let now = now
        let httpClient = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"inference-only-cli","expiresAt":4102444800000,"scopes":["user:inference"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(snapshot.warning, ClaudeAuthError.desktopPermissionRequired.localizedDescription)
        XCTAssertTrue(httpClient.requests.isEmpty)
        XCTAssertEqual(fixture.keyReader.calls, [false])
    }

    func testDesktopCredentialsAreNeverSaved() throws {
        let files = FakeFiles()
        let keychain = FakeKeychain()
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(),
            files: files,
            keychain: keychain,
            desktop: fixture.store,
            now: { now }
        )
        let state = authStore.loadCredentialCandidates().first!

        XCTAssertFalse(try authStore.save(state, ifUnchanged: ClaudeCredentialGeneration([state])))
        XCTAssertTrue(files.files.isEmpty)
        XCTAssertNil(keychain.value)
    }

    @MainActor
    func testDesktop401NeverAttemptsRefreshTokenExchange() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let httpClient = RoutingHTTPClient { request in
            XCTAssertTrue(request.url.absoluteString.hasSuffix("/api/oauth/usage"))
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let now = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(),
                files: fixture.files,
                keychain: FakeKeychain(),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.desktopTokenExpired.localizedDescription)
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    @MainActor
    func testRevokedCLILoginFallsBackToDesktop() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"] ?? ""
            if authorization.contains("desktop-token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertTrue(httpClient.requests.last?.headers["Authorization"]?.contains("desktop-token") == true)
    }

    @MainActor
    func testRevokedCLILoginTriesDesktopBeforeEnvironmentToken() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { request in
            let authorization = request.headers["Authorization"] ?? ""
            if authorization.contains("desktop-token") {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment([
                    "CLAUDE_CONFIG_DIR": "/tmp/claude",
                    "CLAUDE_CODE_OAUTH_TOKEN": "inference-only-env"
                ]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertEqual(httpClient.requests.count, 2)
        XCTAssertTrue(httpClient.requests.last?.headers["Authorization"]?.contains("desktop-token") == true)
    }

    @MainActor
    func testStaleDesktopDoesNotMaskRevokedCLIError() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired-desktop", expiresIn: -1)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await ProviderRefreshContext.$isManual.withValue(true) {
            await provider.refresh()
        }

        XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.tokenExpired.localizedDescription)
        XCTAssertEqual(httpClient.requests.count, 1)
    }

    @MainActor
    func testStaleDesktopDoesNotMaskMissingProfileScopeWarning() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("expired-desktop", expiresIn: -1)]
        )
        let now = now
        let httpClient = RoutingHTTPClient { _ in
            XCTFail("Inference-only credentials must not request live usage")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files,
                keychain: FakeKeychain(
                    #"{"claudeAiOauth":{"accessToken":"inference-only","expiresAt":4102444800000,"scopes":["user:inference"]}}"#
                ),
                desktop: fixture.store,
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            includePiUsage: false,
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.authenticationIssue, .signInNeeded)
        XCTAssertEqual(snapshot.warning, ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertNil(badge(snapshot.lines, "Error"))
        XCTAssertTrue(httpClient.requests.isEmpty)
    }

}
