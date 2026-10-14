import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialBindingCacheTests: XCTestCase {
    private typealias Fixture = CodexBindingTestFixture
    private let storageKey = "source-binding-snapshots"

    func testUnknownFirstCredentialPersistsUnattributedUsageThroughAssemblyAndCatalog() async throws {
        let defaults = makeDefaults()
        let files = CodexBindingFiles([
            "~/.config/codex/auth.json": Fixture.auth(token: "token-a"),
            "~/.codex/auth.json": Fixture.auth(token: "token-b", accountID: "account-b"),
        ])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL { return Fixture.resetCredits }
            return Fixture.quota(used: request.headers["Authorization"] == "Bearer token-a" ? 17 : 91)
        }
        let (assembly, runtime) = try assembledRuntime(files: files, defaults: defaults, http: http)
        XCTAssertNil(assembly.identityKeysByCard["codex"])
        XCTAssertNil(assembly.codexDefaultAccountBinding)
        XCTAssertEqual(runtime.authStore.scope, .standard)
        XCTAssertNil(runtime.authStore.expectedIdentityKey)
        let cache = makeCache(defaults: defaults)
        XCTAssertTrue(cache.loadSnapshots(providerIDs: ["codex"]).isEmpty)
        let store = makeStore(runtime: runtime, assembly: assembly, cache: cache, defaults: defaults)

        let outcome = await store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        let usageRequests = http.requests.filter { $0.url == CodexUsageClient.usageURL }
        XCTAssertEqual(usageRequests.count, 1)
        XCTAssertEqual(usageRequests.first?.headers["Authorization"], "Bearer token-a")
        XCTAssertNil(usageRequests.first?.headers["ChatGPT-Account-Id"])
        XCTAssertFalse(http.requests.contains { $0.headers["Authorization"] == "Bearer token-b" })
        let persistedCache = makeCache(defaults: defaults, allowsPersistedFreshness: true)
        let persisted = try XCTUnwrap(persistedCache.snapshot(providerID: "codex"))
        XCTAssertEqual(persisted.lines, try XCTUnwrap(store.localSnapshots["codex"]).lines)
        guard case .progress(_, let used, _, _, _, _, _) = persisted.lines.first(where: { $0.label == "Session" }) else {
            return XCTFail("A successful quota response must persist its Session metric")
        }
        XCTAssertEqual(used, 17)
        XCTAssertNil(persistedCache.producedByIdentityKey(providerID: "codex"))
    }

    func testBoundFirstCredentialRejectionDoesNotFetchOrCacheSecondAccount() async throws {
        let defaults = makeDefaults()
        let files = CodexBindingFiles([
            "~/.config/codex/auth.json": Fixture.auth(token: "token-a", accountID: "account-a"),
            "~/.codex/auth.json": Fixture.auth(token: "token-b", accountID: "account-b"),
        ])
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == "Bearer token-a" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url == CodexUsageClient.resetCreditsURL { return Fixture.resetCredits }
            return Fixture.quota(used: 91)
        }
        let (assembly, runtime) = try assembledRuntime(files: files, defaults: defaults, http: http)
        let expectedHome = Fixture.home + "/.config/codex"
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "account-a")
        XCTAssertEqual(assembly.codexDefaultAccountBinding, CodexAccountBinding(home: expectedHome, identityKey: "account-a"))
        XCTAssertEqual(runtime.authStore.scope, .home(path: expectedHome))
        XCTAssertEqual(runtime.authStore.expectedIdentityKey, "account-a")
        let cache = makeCache(defaults: defaults)
        XCTAssertTrue(cache.loadSnapshots(providerIDs: ["codex"]).isEmpty)
        let store = makeStore(runtime: runtime, assembly: assembly, cache: cache, defaults: defaults)

        let outcome = await store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL])
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer token-a")
        XCTAssertEqual(http.requests.first?.headers["ChatGPT-Account-Id"], "account-a")
        XCTAssertFalse(http.requests.contains { $0.headers["Authorization"] == "Bearer token-b" })
        XCTAssertNotNil(store.providerErrors["codex"])
        XCTAssertNil(store.localSnapshots["codex"])
        let persistedCache = makeCache(defaults: defaults, allowsPersistedFreshness: true)
        XCTAssertNil(persistedCache.snapshot(providerID: "codex"))
        XCTAssertTrue(persistedCache.loadSnapshots(providerIDs: ["codex"]).isEmpty)
        XCTAssertNil(persistedCache.producedByIdentityKey(providerID: "codex"))
    }

    func testResetClaimRejectsChangedAccountAtBoundPathBeforeAnyRequest() async throws {
        let defaults = makeDefaults()
        let path = Fixture.home + "/.config/codex/auth.json"
        let files = CodexBindingFiles([path: Fixture.auth(token: "token-a", accountID: "account-a")])
        let http = RoutingHTTPClient { _ in Fixture.resetCredits }
        let (_, runtime) = try assembledRuntime(files: files, defaults: defaults, http: http)
        XCTAssertEqual(runtime.authStore.scope, .home(path: Fixture.home + "/.config/codex"))
        XCTAssertEqual(runtime.authStore.expectedIdentityKey, "account-a")
        var refreshCount = 0
        let service = CodexResetClaimService(
            authStore: runtime.authStore,
            usageClient: runtime.usageClient,
            refreshAfterClaim: { _ in refreshCount += 1 }
        )
        let state = try XCTUnwrap(runtime.authStore.loadAuth(at: path))
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: state))
        files.set(Fixture.auth(token: "token-b", accountID: "account-b"), at: path)

        let outcome = await service.claim(
            creditExpiringAt: Fixture.instant.addingTimeInterval(3_600),
            redeemRequestID: "source-binding-claim", binding: binding
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertTrue(files.savedPaths.isEmpty)
    }

    private func assembledRuntime(
        files: CodexBindingFiles, defaults: UserDefaults, http: any HTTPClient
    ) throws -> (ProviderAccountAssembly, CodexProvider) {
        let keychain = CodexBindingKeychain()
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(), files: files, keychain: keychain,
            homeDirectory: { URL(fileURLWithPath: Fixture.home) }
        )
        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults), families: ["codex"]
        )
        let catalog = ProviderCatalog.make(
            defaults: defaults, codexAccountBinding: assembly.codexDefaultAccountBinding
        )
        let catalogCodex = try XCTUnwrap(catalog.compactMap { $0 as? CodexProvider }.first)
        let runtime = CodexProvider(
            provider: catalogCodex.provider,
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: keychain,
                scope: catalogCodex.authStore.scope,
                expectedIdentityKey: catalogCodex.authStore.expectedIdentityKey,
                now: { Fixture.instant }
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: "binding-cache-tests", rootsOverride: []),
            includePiUsage: false, now: { Fixture.instant }, pricing: { .empty }
        )
        return (assembly, runtime)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CodexCredentialBindingCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeCache(defaults: UserDefaults, allowsPersistedFreshness: Bool = false) -> ProviderSnapshotCache {
        ProviderSnapshotCache(
            userDefaults: defaults, storageKey: storageKey, ttl: 600,
            allowsPersistedFreshness: allowsPersistedFreshness, now: { Fixture.instant }
        )
    }

    private func makeStore(
        runtime: CodexProvider, assembly: ProviderAccountAssembly,
        cache: ProviderSnapshotCache, defaults: UserDefaults
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache, defaults: defaults,
            now: { Fixture.instant }, providerIdentityKeys: assembly.identityKeysByCard
        )
    }
}
