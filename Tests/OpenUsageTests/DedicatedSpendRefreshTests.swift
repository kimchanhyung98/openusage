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
        let warning = "Local usage history is unavailable. Showing the last successful totals."
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.warning, warning)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.warningPresentation, [.init(warning)])
        let refreshFailure = fixture.store.refreshResults[fixture.runtime.provider.id]?.failure
        XCTAssertTrue(refreshFailure?.message.contains(warning) == true)
        XCTAssertEqual(refreshFailure?.warningPresentations, [.init(warning)])

        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: [])
        await fixture.store.refreshAll(force: true)
        XCTAssertTrue(total(fixture).slices.isEmpty)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.lines, fixture.previous.lines)
        XCTAssertNil(fixture.store.localSnapshots[fixture.runtime.provider.id]?.warning)
        XCTAssertEqual(fixture.store.refreshResults[fixture.runtime.provider.id]?.failure?.warningPresentations, [])
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

    func testTodaySpendCollectedDuringQuotaFailureSurvivesLaterScanFailure() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let fixture = makeFixture(cached: true, previousDate: yesterday)
        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: lines(cost: 2, tokens: 200))
        await fixture.store.refreshAll(force: true)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.refreshedAt, yesterday)
        let reloadedCache = ProviderSnapshotCache(userDefaults: fixture.defaults, storageKey: "snapshots")
        let cached = reloadedCache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id]
        XCTAssertEqual(cached?.totalSpendRefreshedAt, now)
        XCTAssertEqual(cached?.refreshedAt, yesterday)
        XCTAssertNil(reloadedCache.snapshot(providerID: fixture.runtime.provider.id))

        fixture.runtime.snapshot = ProviderSnapshot.make(
            provider: fixture.runtime.provider, plan: "Pro", lines: fixture.previous.lines,
            refreshedAt: now, warning: "History unavailable"
        )
        let now = now
        let restartedStore = WidgetDataStore(registry: .from([fixture.runtime]), providers: [fixture.runtime],
                                             cache: reloadedCache, defaults: fixture.defaults, now: { now })
        await restartedStore.refreshAll(force: true)

        XCTAssertEqual(TotalSpendAggregator.total(for: .today, providers: [fixture.runtime.provider],
                                                  snapshots: restartedStore.snapshots).slices.first?.tokenCount, 200)
        XCTAssertEqual(reloadedCache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id]?.totalSpendLines,
                       lines(cost: 2, tokens: 200))
    }

    func testQuotaAndScanFailureDoNotKeepPreviousDayTodayTotals() async {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let fixture = makeFixture(cached: true, previousDate: yesterday)
        fixture.runtime.snapshot = failure(fixture.runtime.provider, spend: nil)
        await fixture.store.refreshAll(force: true)

        XCTAssertTrue(total(fixture).slices.isEmpty)
        XCTAssertNil(fixture.cache.loadSnapshots(providerIDs: [fixture.runtime.provider.id])[fixture.runtime.provider.id]?.totalSpendLines)
        XCTAssertNil(fixture.store.localSnapshots[fixture.runtime.provider.id]?.totalSpendRefreshedAt)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.refreshedAt, yesterday)
        XCTAssertEqual(fixture.store.localSnapshots[fixture.runtime.provider.id]?.lines, fixture.previous.lines)
    }

    func testMissingStoreWarnsOnlyWhenPreviousTotalsAreRetained() async {
        for cached in [true, false] {
            let fixture = makeFixture(cached: cached)
            fixture.runtime.snapshot = ProviderSnapshot.make(
                provider: fixture.runtime.provider, plan: "Pro", lines: fixture.previous.lines, refreshedAt: now
            )
            await fixture.store.refreshAll(force: true)

            let snapshot = fixture.store.localSnapshots[fixture.runtime.provider.id]
            XCTAssertEqual(snapshot?.warning != nil, cached)
            XCTAssertEqual(snapshot?.isDegraded == true, cached)
            XCTAssertEqual(total(fixture).slices.first?.tokenCount, cached ? 100 : nil)
            if cached { XCTAssertNotNil(snapshot?.warningPresentation) }
        }
    }

    func testMissingStoreWarnsWhenEmptyPriorTotalsAreRetained() async {
        for quotaFails in [false, true] {
            let fixture = makeFixture(cached: false)
            fixture.runtime.snapshot = ProviderSnapshot.make(
                provider: fixture.runtime.provider, plan: "Pro", lines: fixture.previous.lines,
                totalSpendLines: [], refreshedAt: now.addingTimeInterval(-1)
            )
            await fixture.store.refreshAll(force: true)
            fixture.runtime.snapshot = quotaFails
                ? failure(fixture.runtime.provider, spend: nil)
                : ProviderSnapshot.make(provider: fixture.runtime.provider, plan: "Pro",
                                        lines: fixture.previous.lines, refreshedAt: now)

            await fixture.store.refreshAll(force: true)

            let snapshot = fixture.store.localSnapshots[fixture.runtime.provider.id]
            let warning = "Local usage history is unavailable. Showing the last successful totals."
            XCTAssertEqual(snapshot?.totalSpendLines, [])
            XCTAssertEqual(snapshot?.warning, warning)
            XCTAssertEqual(snapshot?.warningPresentation, [.init(warning)])
            XCTAssertTrue(snapshot?.isDegraded == true)
            XCTAssertTrue(total(fixture).slices.isEmpty)
            if quotaFails {
                XCTAssertEqual(fixture.store.refreshResults[fixture.runtime.provider.id]?.failure?.warningPresentations,
                               [.init(warning)])
            }
        }
    }

    private struct Fixture {
        var runtime: DedicatedSpendRuntime
        var store: WidgetDataStore
        var cache: ProviderSnapshotCache
        var defaults: UserDefaults
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
        return Fixture(runtime: runtime, store: store, cache: cache, defaults: defaults, previous: previous)
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
        snapshot.refreshedAt = now
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
