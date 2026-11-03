import XCTest
@testable import OpenUsage

@MainActor
final class DedicatedSpendRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_577_600)

    func testQuotaFailureUpdatesDedicatedTotalsAndRetainsQuotaAndPlan() async {
        let fixture = makeFixture(cached: true)
        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: lines(cost: 2, tokens: 200))

        await fixture.store.refreshAll(force: true)

        let retained = fixture.store.localSnapshots[fixture.runtime.provider.id]
        XCTAssertEqual(retained?.lines, fixture.previous.lines)
        XCTAssertEqual(retained?.plan, fixture.previous.plan)
        XCTAssertEqual(retained?.refreshedAt, fixture.previous.refreshedAt)
        XCTAssertEqual(retained?.totalSpendLines, lines(cost: 2, tokens: 200))
        XCTAssertEqual(total(fixture).slices.first?.tokenCount, 200)
        XCTAssertNotNil(fixture.store.providerErrors[fixture.runtime.provider.id])
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id]?.totalSpendLines,
                       lines(cost: 2, tokens: 200))
    }

    func testFirstQuotaFailureCanDisplayLocalTotalsWithoutCachingQuotaSuccess() async {
        let fixture = makeFixture(cached: false)
        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: lines(cost: 2, tokens: 200))

        await fixture.store.refreshAll(force: true)

        XCTAssertEqual(total(fixture).slices.first?.amountUSD, 2)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.lines, [])
        XCTAssertNotNil(fixture.store.providerErrors[fixture.runtime.provider.id])
        XCTAssertNil(fixture.cache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id])
    }

    func testMissingScanPreservesPriorTotalsAndConfirmedEmptyScanClearsThem() async {
        let fixture = makeFixture(cached: true)
        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: nil)
        await fixture.store.refreshAll(force: true)
        XCTAssertEqual(total(fixture).slices.first?.amountUSD, 1)

        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: [])
        await fixture.store.refreshAll(force: true)
        XCTAssertTrue(total(fixture).slices.isEmpty)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.lines, fixture.previous.lines)
    }

    func testQuotaSuccessPreservesMissingLocalTotalsAndClearsConfirmedEmptyHistory() async {
        let fixture = makeFixture(cached: true)
        let refreshedQuota: [MetricLine] = [.progress(label: "Credits", used: 30, limit: 100, format: .percent)]
        fixture.runtime.snapshot = ProviderSnapshot.make(
            provider: fixture.runtime.provider, plan: "Pro+", lines: refreshedQuota, refreshedAt: now
        )

        await fixture.store.refreshAll(force: true)

        let retained = fixture.store.localSnapshots[fixture.runtime.provider.id]
        XCTAssertEqual(retained?.lines, refreshedQuota)
        XCTAssertEqual(retained?.plan, "Pro+")
        XCTAssertEqual(retained?.refreshedAt, now)
        XCTAssertEqual(total(fixture).slices.first?.amountUSD, 1)
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id]?.totalSpendLines,
                       fixture.previous.totalSpendLines)

        fixture.runtime.snapshot.totalSpendLines = []
        await fixture.store.refreshAll(force: true)
        XCTAssertTrue(total(fixture).slices.isEmpty)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.lines, refreshedQuota)
    }

    private struct Fixture {
        var runtime: DedicatedSpendRuntime
        var store: WidgetDataStore
        var cache: ProviderSnapshotCache
        var previous: ProviderSnapshot
    }

    private func makeFixture(cached: Bool) -> Fixture {
        let suite = "DedicatedSpendRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let provider = Provider(id: "kiro", displayName: "Kiro", icon: .providerMark("kiro"), usesDedicatedSpendLines: true)
        let previous = ProviderSnapshot.make(
            provider: provider, plan: "Pro",
            lines: [.progress(label: "Credits", used: 25, limit: 100, format: .percent)],
            totalSpendLines: lines(cost: 1, tokens: 100), refreshedAt: now.addingTimeInterval(-600)
        )
        let runtime = DedicatedSpendRuntime(provider: provider, snapshot: previous)
        let now = now
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        if cached { cache.store(previous) }
        let store = WidgetDataStore(registry: .from([runtime]), providers: [runtime], cache: cache,
                                    defaults: defaults, now: { now })
        return Fixture(runtime: runtime, store: store, cache: cache, previous: previous)
    }

    private func total(_ fixture: Fixture) -> TotalSpend {
        TotalSpendAggregator.total(for: .today, providers: [fixture.runtime.provider], snapshots: fixture.store.snapshots)
    }

    private func lines(cost: Double, tokens: Double) -> [MetricLine] {
        [.values(label: "Today", values: [MetricValue(number: cost, kind: .dollars, estimated: true),
                                         MetricValue(number: tokens, kind: .count, label: "tokens")])]
    }

    private func failure(_ provider: Provider, spend: [MetricLine]?) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot.error(provider: provider, message: "Quota unavailable", category: .network)
        snapshot.totalSpendLines = spend
        return snapshot
    }
}

@MainActor
private final class DedicatedSpendRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var snapshot: ProviderSnapshot

    init(provider: Provider, snapshot: ProviderSnapshot) {
        self.provider = provider
        self.snapshot = snapshot
        widgetDescriptors = [.percent(id: "\(provider.id).quota", provider: provider, title: "Credits")]
    }

    func refresh() async -> ProviderSnapshot { snapshot }
}
