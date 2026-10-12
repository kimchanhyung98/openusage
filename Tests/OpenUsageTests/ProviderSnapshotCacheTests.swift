import XCTest
@testable import OpenUsage

final class ProviderSnapshotCacheTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "providerSnapshotCache.test.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func snapshot(_ id: String, used: Double, now: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id,
            displayName: id.capitalized,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now
        )
    }

    func testProviderCadenceAppliesToAppAndPersistedCLICaches() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var now = start
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { now })
        cache.store(snapshot("claude@work", used: 10, now: start))
        cache.store(snapshot("codex", used: 20, now: start))
        now = start.addingTimeInterval(300)
        XCTAssertNil(cache.snapshot(providerID: "codex"))
        XCTAssertNotNil(cache.snapshot(providerID: "claude@work"))
        let cliCache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true, now: { now })
        XCTAssertNotNil(cliCache.snapshot(providerID: "claude@work"))
        XCTAssertNil(cliCache.snapshot(providerID: "codex"))
        now = start.addingTimeInterval(900)
        XCTAssertNil(cache.snapshot(providerID: "claude@work"))
        XCTAssertNil(cliCache.snapshot(providerID: "claude@work"))
    }

    func testCooldownAndLocalRefreshDoNotExtendQuotaFreshness() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { now })
        var cached = snapshot("claude", used: 10, now: now)
        cached.quotaObservedAt = now.addingTimeInterval(-900)
        cached.usageRetryAfter = now.addingTimeInterval(3600)
        cache.store(cached)
        XCTAssertNil(cache.snapshot(providerID: "claude"))
        cached.quotaObservedAt = nil
        cache.store(cached)
        XCTAssertNil(cache.snapshot(providerID: "claude"))
    }

    func testStoreAccumulatesAcrossProvidersAndReadsReflectWrites() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 10, now: now))
        cache.store(snapshot("beta", used: 20, now: now))

        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["alpha", "beta"]).count, 2)
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 10, limit: 100, format: .percent))
        XCTAssertEqual(cache.snapshot(providerID: "beta")?.lines.first,
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))
    }

    func testWritesPersistForAFreshInstance() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now))

        // 새 instance의 mirror는 비어 있으므로 `loadSnapshots` 성공이 disk 기록을 증명
        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["alpha"])["alpha"]?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    func testRelaunchLoadedSnapshotIsStaleEvenWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
            .store(snapshot("alpha", used: 42, now: now.addingTimeInterval(-1)))

        let relaunched = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })
        XCTAssertNotNil(relaunched.loadSnapshots(providerIDs: ["alpha"])["alpha"])
        XCTAssertNil(relaunched.snapshot(providerID: "alpha"))
    }

    func testSnapshotWrittenThisSessionStaysFreshWithinTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 9_999, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        XCTAssertEqual(cache.snapshot(providerID: "alpha")?.lines.first,
                       .progress(label: "Session", used: 42, limit: 100, format: .percent))
    }

    func testSnapshotWrittenThisSessionExpiresAfterTTL() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "k", ttl: 100, now: { now })

        cache.store(snapshot("alpha", used: 42, now: now))
        now = now.addingTimeInterval(101)
        XCTAssertNil(cache.snapshot(providerID: "alpha"))
    }
}
