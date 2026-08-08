import XCTest
@testable import OpenUsage

@MainActor
final class StalenessLabelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshSnapshotHasNoStalenessLabel() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now)
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testSnapshotWithinThresholdHasNoStalenessLabel() {
        // refresh interval 1회분은 정상 — threshold는 단일 interval보다 큼
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-RefreshSetting.interval))
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testStaleSnapshotSurfacesOutdatedHint() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-3 * 60 * 60))
        XCTAssertEqual(store.stalenessHint(for: "devin"),
                       StalenessHint(label: "Outdated", tooltip: "Last updated 3h ago"))
    }

    func testSnapshotExactlyAtThresholdIsStale() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-WidgetDataStore.stalenessThreshold))
        XCTAssertNotNil(store.stalenessHint(for: "devin"))
    }

    func testSnapshotJustBelowThresholdIsNotStale() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-(WidgetDataStore.stalenessThreshold - 1)))
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testVeryStaleSnapshotFormatsTooltipInDays() {
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(-3 * 24 * 60 * 60))
        XCTAssertEqual(store.stalenessHint(for: "devin")?.tooltip, "Last updated 3d 0h ago")
    }

    func testFutureRefreshedAtHasNoStalenessLabel() {
        // clock skew로 미래 시각이 찍힐 수 있음 — 음수 age는 hint 미표시
        let store = makeStore()
        store.snapshots["devin"] = snapshot(refreshedAt: now.addingTimeInterval(60 * 60))
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testMissingSnapshotHasNoStalenessLabel() {
        let store = makeStore()
        XCTAssertNil(store.stalenessHint(for: "devin"))
    }

    func testFailingRefreshKeepsFossilButLabelsItStale() async {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: .error(provider: provider, message: "Not logged in")
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime)
        store.snapshots["devin"] = ProviderSnapshot(
            providerID: "devin", displayName: "Devin", plan: "Team 5x",
            lines: [.progress(label: "Weekly quota", used: 40, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-3 * 60 * 60)
        )

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.plan(for: "devin"), "Team 5x", "stale-while-revalidate keeps the last good snapshot")
        XCTAssertNotNil(store.errorMessage(for: "devin"), "the failed refresh still raises the warning")
        XCTAssertEqual(store.stalenessHint(for: "devin"),
                       StalenessHint(label: "Outdated", tooltip: "Last updated 3h ago"),
                       "the fossil is now visibly labelled as old")
    }

    // MARK: - Helpers

    private func snapshot(refreshedAt: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "devin", displayName: "Devin", plan: "Team 5x",
            lines: [.progress(label: "Weekly quota", used: 40, limit: 100, format: .percent)],
            refreshedAt: refreshedAt
        )
    }

    private func makeStore() -> WidgetDataStore {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(provider: provider, descriptors: [descriptor],
                                          snapshot: snapshot(refreshedAt: now))
        return makeStore(provider: provider, descriptor: descriptor, runtime: runtime)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: some ProviderRuntime
    ) -> WidgetDataStore {
        let suiteName = "OpenUsageTests.Staleness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { self.now }),
            defaults: defaults,
            now: { self.now }
        )
    }
}
