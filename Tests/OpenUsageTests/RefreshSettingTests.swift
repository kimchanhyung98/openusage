import XCTest
@testable import OpenUsage

@MainActor
final class RefreshSettingTests: XCTestCase {
    // MARK: - Fixed cadence

    func testCadenceIsFixedAtFiveMinutes() {
        XCTAssertEqual(RefreshSetting.defaultMinutes, 5)
        XCTAssertEqual(RefreshSetting.interval, 300)
    }

    // MARK: - Session-scoped freshness

    func testRelaunchRefetchesEvenWithinIntervalButPaintsCachedValueFirst() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-within")

        storeSnapshot(used: 20, age: 240, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 20, limit: 100, format: .percent))

        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.snapshots["test"]?.line(label: "Session"),
                       .progress(label: "Session", used: 80, limit: 100, format: .percent))
    }

    func testWithinSessionPassServedFromCacheUntilInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("within-session")

        // cache instance 공유로 단일 session 재현 — 이번 session 4분 전 fetch라 pass short-circuit
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-240)
        ))

        let runtime = makeRuntime(used: 80)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: cache,
            defaults: suite
        )
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertNotNil(store.snapshots["test"])
    }

    func testCacheExpiresPastInterval() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let suite = makeDefaults("restart-expired")

        storeSnapshot(used: 20, age: 360, into: suite, now: now)

        let runtime = makeRuntime(used: 80)
        let store = makeStore(runtime: runtime, suite: suite, now: now)
        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
    }

    // MARK: - Helpers

    private func storeSnapshot(used: Double, age: TimeInterval, into suite: UserDefaults, now: Date) {
        let cache = ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now })
        cache.store(ProviderSnapshot(
            providerID: "test",
            displayName: "Test",
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-age)
        ))
    }

    private func makeRuntime(used: Double) -> CountingProviderRuntime {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: "test",
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: used, limit: 100)
        )
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: "test",
                displayName: "Test",
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
                refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    /// 기본 refresh-interval TTL cache 기반 store — 재실행 케이스용
    private func makeStore(runtime: CountingProviderRuntime, suite: UserDefaults, now: Date) -> WidgetDataStore {
        WidgetDataStore(
            registry: WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", now: { now }),
            defaults: suite
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.RefreshSetting.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
