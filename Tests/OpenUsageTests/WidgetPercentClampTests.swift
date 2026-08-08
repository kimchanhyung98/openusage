import XCTest
@testable import OpenUsage

@MainActor
final class WidgetPercentClampTests: XCTestCase {
    func testNegativePercentSampleNeverRendersNegative() async {
        let (store, descriptor) = await makePercentStore(used: -5, suite: "negative")

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.used, 0)
        XCTAssertEqual(remaining.valueText, "100%")
        XCTAssertEqual(remaining.boundedHeadline, "100% left")
        XCTAssertEqual(remaining.menuBarValue, "100%")
        XCTAssertEqual(remaining.meterStyleTooltip, "0% used")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.valueText, "0%")
        XCTAssertEqual(used.boundedHeadline, "0% used")
        XCTAssertEqual(used.menuBarValue, "0%")
        XCTAssertEqual(used.meterStyleTooltip, "100% left")
    }

    func testOverHundredPercentSampleNeverRendersOverHundred() async {
        let (store, descriptor) = await makePercentStore(used: 130, suite: "over")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.used, 100)
        XCTAssertEqual(used.valueText, "100%")
        XCTAssertEqual(used.boundedHeadline, "100% used")
        XCTAssertEqual(used.menuBarValue, "100%")
        XCTAssertEqual(used.meterState(), .spent)

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertEqual(remaining.valueText, "0%")
        XCTAssertEqual(remaining.boundedHeadline, "0% left")
        XCTAssertEqual(remaining.menuBarValue, "0%")
    }

    // MARK: - Helper

    /// provider 공통 resolve 경로에 범위 밖 percent를 주입하는 fixture
    private func makePercentStore(used: Double, suite: String) async -> (WidgetDataStore, WidgetDescriptor) {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.metric",
            providerID: provider.id,
            metricLabel: "Metric",
            sample: WidgetData(title: "Metric", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Metric", used: used, limit: 100, format: .percent)]
            )
        )
        let suiteName = "OpenUsageTests.PercentClamp.\(suite).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )
        await store.refreshAll()
        return (store, descriptor)
    }
}
