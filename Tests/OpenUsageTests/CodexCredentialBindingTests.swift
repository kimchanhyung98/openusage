import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialBindingTests: XCTestCase {
    private nonisolated static let home = "/Users/source-binding-test"
    private nonisolated static let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private var boundPath: String { Self.home + "/.config/codex/auth.json" }

    func testUnknownFirstCredentialClearsPreviousAccountStampAfterRefresh() async throws {
        let files = makeFiles(firstAccount: nil)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL { return Self.resetCredits }
            return Self.quota(used: request.headers["Authorization"] == "Bearer token-a" ? 17 : 91)
        }
        let fixture = try makeFixture(files: files, http: http, previousIdentity: "account-b")

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        let requests = http.requests.filter { $0.url == CodexUsageClient.usageURL }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.headers["Authorization"], "Bearer token-a")
        XCTAssertNil(requests.first?.headers["ChatGPT-Account-Id"])
        XCTAssertFalse(http.requests.contains { $0.headers["Authorization"] == "Bearer token-b" })
        let persisted = makeCache(defaults: fixture.defaults, allowsPersistedFreshness: true)
        XCTAssertEqual(try sessionUsage(persisted.snapshot(providerID: "codex")), 17)
        XCTAssertNil(persisted.producedByIdentityKey(providerID: "codex"))
    }

    func testBoundAuthenticationFailureKeepsPreviousUsageWithoutFetchingAnotherAccount() async throws {
        let files = makeFiles(firstAccount: "account-a")
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer token-a" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url == CodexUsageClient.resetCreditsURL { return Self.resetCredits }
            return Self.quota(used: 91)
        }
        let fixture = try makeFixture(files: files, http: http, previousIdentity: "account-a")

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL])
        XCTAssertEqual(http.requests.first?.headers["ChatGPT-Account-Id"], "account-a")
        XCTAssertNotNil(fixture.store.providerErrors["codex"])
        XCTAssertEqual(try sessionUsage(fixture.store.localSnapshots["codex"]), 20)
        let persisted = makeCache(defaults: fixture.defaults, allowsPersistedFreshness: true)
        XCTAssertEqual(try sessionUsage(persisted.snapshot(providerID: "codex")), 20)
        XCTAssertEqual(persisted.producedByIdentityKey(providerID: "codex"), "account-a")
    }

    func testChangedBoundAccountIsRejectedBeforeAnyRequest() async throws {
        let files = makeFiles(firstAccount: "account-a")
        let http = RoutingHTTPClient { request in
            XCTFail("Changed credentials must not reach HTTP: \(request.url)")
            return Self.quota(used: 91)
        }
        let fixture = try makeFixture(files: files, http: http)
        let replacement = Self.auth(token: "token-b", accountID: "account-b")
        files.files[boundPath] = replacement

        let snapshot = await fixture.runtime.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files[boundPath], replacement)
    }

    func testInFlightAccountChangeIsRejectedButSameAccountTokenRotationIsAccepted() async throws {
        for accountID in ["account-b", "account-a"] {
            let files = makeFiles(firstAccount: "account-a")
            let path = boundPath
            let replacement = Self.auth(token: "rotated-token", accountID: accountID)
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.usageURL {
                    files.files[path] = replacement
                    return Self.quota(used: 37)
                }
                return Self.resetCredits
            }
            let fixture = try makeFixture(files: files, http: http)

            let snapshot = await fixture.runtime.refresh()

            if accountID == "account-a" {
                XCTAssertNil(snapshot.errorCategory)
                XCTAssertEqual(try sessionUsage(snapshot), 37)
                XCTAssertNotNil(fixture.runtime.weeklyTimerObservation)
            } else {
                XCTAssertEqual(snapshot.errorCategory, .other)
                XCTAssertNil(snapshot.line(label: "Session"))
                XCTAssertNil(snapshot.liveQuotaObservedAt)
                XCTAssertNil(fixture.runtime.weeklyTimerObservation)
            }
            XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.usageURL }.count, 1)
            XCTAssertTrue(http.requests.allSatisfy { $0.headers["ChatGPT-Account-Id"] == "account-a" })
            XCTAssertEqual(files.files[path], replacement)
        }
    }

    private func makeFixture(
        files: FakeFiles, http: any HTTPClient, previousIdentity: String? = nil
    ) throws -> (runtime: CodexProvider, store: WidgetDataStore, defaults: UserDefaults) {
        let suite = "CodexCredentialBindingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let keychain = FakeKeychain()
        let assembly = ProviderAccountAssembly.make(
            observer: DefaultAccountObserver(
                environment: FakeEnvironment(), files: files, keychain: keychain,
                homeDirectory: { URL(fileURLWithPath: Self.home) }
            ),
            accountsStore: ProviderAccountsStore(defaults: defaults), families: ["codex"]
        )
        let catalog = ProviderCatalog.make(
            defaults: defaults, codexAccountBinding: assembly.codexDefaultAccountBinding
        )
        let catalogCodex = try XCTUnwrap(catalog.compactMap { $0 as? CodexProvider }.first)
        let runtime = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: keychain,
                scope: catalogCodex.authStore.scope,
                expectedIdentityKey: catalogCodex.authStore.expectedIdentityKey, now: { Self.instant }
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: suite, rootsOverride: []),
            includePiUsage: false, now: { Self.instant }, pricing: { .empty }
        )
        if let previousIdentity {
            let lines = try CodexUsageMapper.mapUsageResponse(Self.quota(used: 20), now: Self.instant).lines
            makeCache(defaults: defaults).store(
                ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: lines, refreshedAt: Self.instant),
                producedByIdentityKey: previousIdentity
            )
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: makeCache(defaults: defaults), defaults: defaults, now: { Self.instant },
            providerIdentityKeys: assembly.identityKeysByCard
        )
        return (runtime, store, defaults)
    }

    private func makeFiles(firstAccount: String?) -> FakeFiles {
        let first = Self.auth(token: "token-a", accountID: firstAccount)
        let second = Self.auth(token: "token-b", accountID: "account-b")
        return FakeFiles([
            Self.home + "/.config/codex/auth.json": first, "~/.config/codex/auth.json": first,
            Self.home + "/.codex/auth.json": second, "~/.codex/auth.json": second,
        ])
    }

    private func makeCache(defaults: UserDefaults, allowsPersistedFreshness: Bool = false) -> ProviderSnapshotCache {
        ProviderSnapshotCache(
            userDefaults: defaults, storageKey: "binding-cache", ttl: 600,
            allowsPersistedFreshness: allowsPersistedFreshness, now: { Self.instant }
        )
    }

    private func sessionUsage(_ snapshot: ProviderSnapshot?) throws -> Double {
        let line = try XCTUnwrap(snapshot?.line(label: "Session"))
        guard case .progress(_, let used, _, _, _, _, _) = line else {
            XCTFail("Expected a Session usage metric")
            return -.infinity
        }
        return used
    }

    private nonisolated static func auth(token: String, accountID: String?) -> String {
        let auth = CodexAuth(tokens: CodexTokens(
            accessToken: token, idToken: "e30.eyJzdWIiOiJ1c2VyLWEifQ.sig", accountID: accountID
        ))
        return String(decoding: try! JSONEncoder().encode(auth), as: UTF8.self)
    }

    private nonisolated static func quota(used: Double) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data("""
        {"rate_limit":{
          "primary_window":{"used_percent":\(used),"limit_window_seconds":18000},
          "secondary_window":{"used_percent":0,"limit_window_seconds":604800}
        }}
        """.utf8))
    }

    private nonisolated static var resetCredits: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"available_count":0}"#.utf8))
    }
}
