import XCTest
@testable import OpenUsage

@MainActor
final class DedicatedSpendRefreshTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!

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

    func testFirstQuotaFailureCanDisplayLocalTotalsWithoutCachingQuotaSuccess() async throws {
        let fixture = makeFixture(cached: false)
        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: lines(cost: 2, tokens: 200))

        await fixture.store.refreshAll(force: true)

        XCTAssertEqual(total(fixture).slices.first?.amountUSD, 2)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.lines, [])
        XCTAssertNotNil(fixture.store.providerErrors[fixture.runtime.provider.id])
        XCTAssertNil(fixture.cache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id])
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: [fixture.runtime.provider.id], knownIDs: [fixture.runtime.provider.id],
            snapshots: fixture.store.snapshots, limitDescriptors: fixture.store.limitDescriptorsByProvider,
            errors: fixture.store.providerErrors, generatedAt: now
        )
        let response = try XCTUnwrap(JSONSerialization.jsonObject(
            with: LocalLimitsAPI.encode(providerIDs: state.enabledOrderedIDs, state: state)
        ) as? [String: Any])
        XCTAssertEqual((response["providers"] as? [String: Any])?.count, 0)
        XCTAssertEqual((response["errors"] as? [[String: Any]])?.count, 1)
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

    func testSuccessfulQuotaRetainsOnlyOptedInSameDayTotals() async {
        for retainsSpend in [true, false] {
            let fixture = makeFixture(cached: true, retainsSpend: retainsSpend)
            fixture.runtime.snapshot = ProviderSnapshot.make(
                provider: fixture.runtime.provider, plan: "New plan",
                lines: [.progress(label: "Credits", used: 40, limit: 100, format: .percent)],
                refreshedAt: now, warning: "History unavailable"
            )
            await fixture.store.refreshAll(force: true)
            let snapshot = fixture.store.localSnapshots[fixture.runtime.provider.id]
            XCTAssertEqual(snapshot?.totalSpendLines, retainsSpend ? fixture.previous.totalSpendLines : nil)
            XCTAssertEqual(snapshot?.plan, "New plan")
            XCTAssertEqual(snapshot?.refreshedAt, now)
            XCTAssertEqual(snapshot?.warning, "History unavailable")
            XCTAssertNil(fixture.store.providerErrors[fixture.runtime.provider.id])
        }
    }

    func testSuccessfulQuotaDoesNotRelabelPreviousDayTotals() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let fixture = makeFixture(cached: true, previousDate: yesterday)
        fixture.runtime.snapshot = ProviderSnapshot.make(
            provider: fixture.runtime.provider, plan: "Pro", lines: fixture.previous.lines,
            refreshedAt: now, warning: "History unavailable"
        )
        await fixture.store.refreshAll(force: true)
        XCTAssertNil(fixture.store.localSnapshots[fixture.runtime.provider.id]?.totalSpendLines)
        XCTAssertTrue(total(fixture).slices.isEmpty)
    }

    private struct Fixture {
        var runtime: DedicatedSpendRuntime
        var store: WidgetDataStore
        var cache: ProviderSnapshotCache
        var previous: ProviderSnapshot
    }

    private func makeFixture(cached: Bool, retainsSpend: Bool = true, previousDate: Date? = nil) -> Fixture {
        let suite = "DedicatedSpendRefreshTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let provider = Provider(id: "kiro", displayName: "Kiro", icon: .providerMark("kiro"), usesDedicatedSpendLines: true)
        let previous = ProviderSnapshot.make(
            provider: provider, plan: "Pro",
            lines: [.progress(label: "Credits", used: 25, limit: 100, format: .percent)],
            totalSpendLines: lines(cost: 1, tokens: 100), refreshedAt: previousDate ?? now.addingTimeInterval(-600)
        )
        let runtime = DedicatedSpendRuntime(provider: provider, snapshot: previous, retainsSpend: retainsSpend)
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
    let retainsDedicatedSpendOnScanFailure: Bool

    init(provider: Provider, snapshot: ProviderSnapshot, retainsSpend: Bool) {
        self.provider = provider
        self.snapshot = snapshot
        retainsDedicatedSpendOnScanFailure = retainsSpend
        widgetDescriptors = [.percent(id: "\(provider.id).quota", provider: provider, title: "Credits")]
    }

    func refresh() async -> ProviderSnapshot { snapshot }
}
