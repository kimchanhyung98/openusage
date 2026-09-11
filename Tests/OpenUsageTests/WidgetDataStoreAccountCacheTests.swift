import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreAccountCacheTests: XCTestCase {
    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "WidgetDataStoreAccountCacheTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: id.capitalized, icon: .providerMark("codex"))
    }

    private func snapshot(_ id: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: Date()
        )
    }

    private func makeStore(
        providers: [Provider],
        cache: ProviderSnapshotCache,
        defaults: UserDefaults,
        identityKeys: [String: String]
    ) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: providers, descriptors: []),
            providers: [],
            cache: cache,
            defaults: defaults,
            providerIdentityKeys: identityKeys
        )
    }

    func testMatchingStampKeepsCachedEntryAtLaunch() {
        let defaults = makeUserDefaults("match")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")

        let store = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-A"]
        )
        XCTAssertNotNil(store.snapshots["claude"])
    }

    func testMismatchedStampDropsOnlyThatEntry() {
        let defaults = makeUserDefaults("mismatch")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-OLD")
        cache.store(snapshot("codex", used: 50), producedByIdentityKey: "acct-B")

        let store = makeStore(
            providers: [provider("claude"), provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-NEW", "codex": "acct-B"]
        )
        XCTAssertNil(store.snapshots["claude"], "swapped account's cached snapshot must not paint")
        XCTAssertNotNil(store.snapshots["codex"], "unswapped card must keep its cache")
    }

    func testNilStampWithKnownIdentityIsDropped() {
        let defaults = makeUserDefaults("nil-stamp")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("codex", used: 40))

        let store = makeStore(
            providers: [provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["codex": "acct-A"]
        )
        XCTAssertNil(store.snapshots["codex"])
    }

    func testUnresolvedCurrentIdentityKeepsEntry() {
        let defaults = makeUserDefaults("no-identity")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        cache.store(snapshot("codex", used: 50))

        let store = makeStore(
            providers: [provider("claude"), provider("codex")],
            cache: cache,
            defaults: defaults,
            identityKeys: [:]
        )
        XCTAssertNotNil(store.snapshots["claude"])
        XCTAssertNotNil(store.snapshots["codex"])
    }

    func testNonAccountProviderLoadsRegardlessOfStamp() {
        let defaults = makeUserDefaults("non-account")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("cursor", used: 40))
        cache.store(snapshot("grok", used: 50), producedByIdentityKey: "stray-stamp")

        let store = makeStore(
            providers: [provider("cursor"), provider("grok")],
            cache: cache,
            defaults: defaults,
            identityKeys: [:]
        )
        XCTAssertNotNil(store.snapshots["cursor"])
        XCTAssertNotNil(store.snapshots["grok"])
    }

    func testRefreshNeverCacheHitsAMismatchedStampEntry() async {
        let defaults = makeUserDefaults("refresh-gate")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-OLD")

        let swapped = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-NEW"]
        )
        // runtime 미등록 fixture — cache gate 통과 시 `.skipped`, stale entry 사용 시 `.cacheHit`
        let gated = await swapped.refresh(providerID: "claude")
        XCTAssertEqual(gated, .skipped, "a mismatched stamp must fall through to a real fetch")

        let sameAccount = makeStore(
            providers: [provider("claude")],
            cache: cache,
            defaults: defaults,
            identityKeys: ["claude": "acct-OLD"]
        )
        let honored = await sameAccount.refresh(providerID: "claude")
        XCTAssertEqual(honored, .cacheHit)
    }

    func testKnownToUnresolvedIdentityCannotReuseFreshCache() async {
        let defaults = makeUserDefaults("known-to-unresolved")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600)
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-a")
        let store = makeStore(providers: [provider("claude")], cache: cache, defaults: defaults,
                              identityKeys: ["claude": "acct-a"])
        store.replaceProviderCatalog(
            registry: WidgetRegistry(providers: [provider("claude")], descriptors: []),
            providers: [], identityKeys: [:]
        )
        XCTAssertNil(store.localSnapshots["claude"])

        let outcome = await store.refresh(providerID: "claude")

        XCTAssertEqual(outcome, .skipped, "an unresolved identity must reach the runtime instead of reusing rejected cache")
        XCTAssertNil(store.snapshots["claude"])
        XCTAssertNotNil(cache.snapshot(providerID: "claude"), "the persisted last-good cache must remain intact")
    }

    func testUnresolvedAssemblyChangeCannotRestorePreviouslyRejectedCache() {
        let defaults = makeUserDefaults("unresolved-assembly")
        let files = FakeFiles([
            "/Users/fixture/.claude.json": #"{"oauthAccount":{"accountUuid":"ACCT-A"}}"#,
            "/Users/fixture/.codex/auth.json": #"{"tokens":{"access_token":"fixture","account_id":"CODEX-A"}}"#,
        ])
        let accounts = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(environment: FakeEnvironment(), files: files,
                                              keychain: FakeKeychain(nil),
                                              homeDirectory: { URL(fileURLWithPath: "/Users/fixture") })
        let known = ProviderAccountAssembly.make(observer: observer, accountsStore: accounts)
        let registry = WidgetRegistry(providers: [provider("claude"), provider("codex")], descriptors: [])
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600)
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-a")
        let store = makeStore(providers: registry.providers, cache: cache, defaults: defaults,
                              identityKeys: known.identityKeysByCard)
        files.files["/Users/fixture/.claude.json"] = #"{"oauthAccount":{}}"#
        let unresolved = ProviderAccountAssembly.make(observer: observer, accountsStore: accounts)
        XCTAssertNotEqual(known, unresolved)
        XCTAssertNil(unresolved.identityKeysByCard["claude"])
        store.replaceProviderCatalog(registry: registry, providers: [], identityKeys: unresolved.identityKeysByCard)
        XCTAssertNil(store.localSnapshots["claude"])

        files.files["/Users/fixture/.codex/auth.json"] = #"{"tokens":{"access_token":"fixture","account_id":"CODEX-B"}}"#
        let changed = ProviderAccountAssembly.make(observer: observer, accountsStore: accounts)
        XCTAssertNotEqual(unresolved, changed, "the app only replaces catalogs when the assembly changes")
        XCTAssertNil(changed.identityKeysByCard["claude"])
        store.replaceProviderCatalog(registry: registry, providers: [], identityKeys: changed.identityKeysByCard)

        XCTAssertNil(store.snapshots["claude"], "another family's assembly change must not restore the rejected entry")
    }

    func testMatchingIdentityCanRestoreCacheAfterUnresolvedPeriod() async {
        let defaults = makeUserDefaults("identity-restored")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600)
        let original = snapshot("claude", used: 40)
        cache.store(original, producedByIdentityKey: "acct-a")
        let registry = WidgetRegistry(providers: [provider("claude")], descriptors: [])
        let store = makeStore(providers: registry.providers, cache: cache, defaults: defaults,
                              identityKeys: ["claude": "acct-a"])
        store.replaceProviderCatalog(registry: registry, providers: [], identityKeys: [:])
        store.replaceProviderCatalog(registry: registry, providers: [], identityKeys: ["claude": "acct-a"])

        let outcome = await store.refresh(providerID: "claude")

        XCTAssertEqual(outcome, .cacheHit)
        XCTAssertEqual(store.localSnapshots["claude"], original)
    }

    func testSuccessfulUnresolvedFetchReplacesRejectedCache() async {
        let defaults = makeUserDefaults("unresolved-success")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600)
        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-a")
        let current = snapshot("claude", used: 55)
        let runtime = CountingProviderRuntime(provider: provider("claude"), descriptors: [], snapshot: current)
        let registry = WidgetRegistry.from([runtime])
        let store = makeStore(providers: registry.providers, cache: cache, defaults: defaults,
                              identityKeys: ["claude": "acct-a"])
        store.replaceProviderCatalog(registry: registry, providers: [runtime], identityKeys: [:])

        let first = await store.refresh(providerID: "claude")
        let second = await store.refresh(providerID: "claude")

        XCTAssertEqual(first, .refreshed)
        XCTAssertEqual(second, .cacheHit)
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.snapshots["claude"], current)
        XCTAssertNil(cache.producedByIdentityKey(providerID: "claude"))
    }

    func testHasStaleAccountStampSemantics() {
        let defaults = makeUserDefaults("predicate")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-A"), "no entry, nothing to distrust")

        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-A"))
        XCTAssertFalse(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: nil), "unresolved identity can't prove staleness")
        XCTAssertTrue(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-B"))

        cache.store(snapshot("claude", used: 41))
        XCTAssertTrue(cache.hasStaleAccountStamp(providerID: "claude", currentIdentityKey: "acct-A"), "an unstamped entry is unattributable")
    }

    func testStoreStampsAndClearsProducerIdentity() {
        let defaults = makeUserDefaults("stamp-write")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        cache.store(snapshot("claude", used: 40), producedByIdentityKey: "acct-A")
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "claude"), "acct-A")

        cache.store(snapshot("claude", used: 41))
        XCTAssertNil(cache.producedByIdentityKey(providerID: "claude"))
    }
}
