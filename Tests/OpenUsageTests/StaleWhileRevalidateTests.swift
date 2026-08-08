import Observation
import os
import XCTest
@testable import OpenUsage

@MainActor
final class StaleWhileRevalidateTests: XCTestCase {
    func testExpiredSnapshotStillLoadsAtLaunchThenRefreshes() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("stale-launch")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSinceNow: -7200)
        ))

        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 55, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )

        XCTAssertEqual(store.data(for: descriptor).used, 40)
        XCTAssertTrue(store.data(for: descriptor).hasData)

        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).used, 55)
    }

    func testFailedRefreshKeepsLastGoodSnapshotAndRecordsError() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("error-keeps-stale")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        await store.refreshAll(force: true)
        XCTAssertTrue(store.data(for: descriptor).hasData)
        XCTAssertNil(store.errorMessage(for: provider.id))

        runtime.snapshot = ProviderSnapshot.error(provider: provider, message: "Not signed in")
        await store.refreshAll(force: true)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Not signed in")
        XCTAssertTrue(store.data(for: descriptor).hasData)
        XCTAssertEqual(store.data(for: descriptor).used, 40)

        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: 60, limit: 100, format: .percent)]
        )
        await store.refreshAll(force: true)
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertEqual(store.data(for: descriptor).used, 60)
    }

    func testSuccessfulRefreshWithoutHistoryPreservesOnlyLastGoodHistory() async throws {
        let provider = Self.testProvider
        let quota = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let historyDescriptor = UsageHistoryDescriptor(
            scope: .machineLocal,
            estimatedCost: true,
            sourceNote: "From test logs"
        )
        let trend = WidgetDescriptor.usageTrend(provider: provider).exportingHistory(
            scope: historyDescriptor.scope,
            estimatedCost: historyDescriptor.estimatedCost,
            sourceNote: historyDescriptor.sourceNote
        )
        let spend = WidgetDescriptor.spendTiles(provider: provider)
        let descriptors = [quota, trend] + spend
        let defaults = makeUserDefaults("history-scan-miss")
        let fixedNow = Date(timeIntervalSince1970: 1_752_364_800)
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(
                    date: DailyUsageAccumulator.dayKey(from: fixedNow),
                    totalTokens: 400,
                    costUSD: 4
                )
            ]),
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(
                    date: DailyUsageAccumulator.dayKey(from: fixedNow),
                    models: [ModelUsageEntry(model: "Test Model", totalTokens: 400, costUSD: 4)]
                )
            ])
        )
        var firstSnapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Original",
            lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
            refreshedAt: fixedNow,
            usageHistory: history
        )
        firstSnapshot = UsageHistorySnapshotRenderer.render(
            local: firstSnapshot,
            history: history,
            descriptor: historyDescriptor,
            now: fixedNow,
            combined: false
        )
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: firstSnapshot
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: descriptors),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            now: { fixedNow }
        )

        await store.refreshAll(force: true)
        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Current",
            lines: [.progress(label: "Alpha", used: 60, limit: 100, format: .percent)],
            refreshedAt: fixedNow.addingTimeInterval(300)
        )
        await store.refreshAll(force: true)

        let refreshed = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(refreshed.plan, "Current")
        XCTAssertEqual(store.data(for: quota).used, 60)
        XCTAssertEqual(refreshed.usageHistory, history)
        guard case .values(_, _, _, _, _, let breakdown) = refreshed.line(label: "Today") else {
            return XCTFail("The retained history should rebuild the spend rows")
        }
        XCTAssertEqual(breakdown?.sourceNote, historyDescriptor.sourceNote)
    }

    func testCacheHitRefreshDoesNotInvalidateSnapshotObservers() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("cache-hit-no-invalidation")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        // TTL 이내 cached snapshot — store init 시 `snapshots`에 로드됨
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)]
        ))

        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 55, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )

        // `onChange`가 `@Sendable`이라 lock-box 사용 — write 중 동기 발화, pass 후 판독 결정적
        let snapshotsInvalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.snapshots
        } onChange: {
            snapshotsInvalidated.withLock { $0 = true }
        }

        await store.refreshAll()

        XCTAssertFalse(snapshotsInvalidated.withLock { $0 })
        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).used, 40)
    }

    func testErrorBeforeAnyDataShowsNoDataPlusError() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("error-no-data")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot.error(provider: provider, message: "Not signed in")
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )

        await store.refreshAll(force: true)
        XCTAssertFalse(store.data(for: descriptor).hasData)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Not signed in")
    }

    func testCancelledRefreshKeepsLastGoodHistoryAndSkipsPublication() async throws {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("cancelled-history")
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-07-17", totalTokens: 400, costUSD: 4)
            ])
        )
        let runtime = BlockingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                plan: "Last good",
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
                usageHistory: history
            )
        )
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: defaults
        )
        _ = await store.refresh(providerID: provider.id, force: true)
        var historyChangeCount = 0
        store.onLocalHistoryChanged = { historyChangeCount += 1 }

        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Partial cancelled result",
            lines: [.progress(label: "Alpha", used: 0, limit: 100, format: .percent)],
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
        runtime.blockNextRefresh = true
        let task = Task {
            await store.refresh(providerID: provider.id, force: true)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !runtime.isWaiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard runtime.isWaiting else {
            runtime.resume()
            task.cancel()
            _ = await task.value
            return XCTFail("the provider refresh did not suspend before the timeout")
        }
        task.cancel()
        runtime.resume()

        let outcome = await task.value
        guard case .skipped = outcome else {
            return XCTFail("a canceled provider refresh must be skipped")
        }
        let retained = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(retained.plan, "Last good")
        XCTAssertEqual(retained.usageHistory, history)
        XCTAssertEqual(historyChangeCount, 0)
        XCTAssertFalse(store.refreshingProviderIDs.contains(provider.id))
        XCTAssertEqual(cache.loadSnapshots(providerIDs: [provider.id])[provider.id]?.plan, "Last good")
    }

    func testAccountSelectionRefreshWaitsForAnInFlightProviderRefresh() async throws {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let runtime = BlockingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 55, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: makeUserDefaults("account-selection-race"), storageKey: "snapshots")
        )

        runtime.blockNextRefresh = true
        let inFlight = Task { await store.refresh(providerID: provider.id, force: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !runtime.isWaiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard runtime.isWaiting else {
            inFlight.cancel()
            return XCTFail("the initial refresh did not enter the in-flight state")
        }

        let selected = Task {
            await store.refreshAfterAccountSelection(
                providerID: provider.id,
                maxAttempts: 20,
                retryDelay: .milliseconds(1)
            )
        }
        try? await Task.sleep(for: .milliseconds(5))
        runtime.resume()
        _ = await inFlight.value
        await selected.value

        XCTAssertEqual(runtime.refreshCount, 2, "the selected account must receive its own refresh after the overlap clears")
        XCTAssertEqual(store.data(for: descriptor).used, 55)
    }

    func testReplacingCatalogWithANewIdentityClearsTheSameCardsState() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let cache = ProviderSnapshotCache(userDefaults: makeUserDefaults("identity-swap-purge"), storageKey: "snapshots")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            providerIdentityKeys: [provider.id: "acct-a"]
        )
        _ = await store.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(store.data(for: descriptor).used, 40)

        store.replaceProviderCatalog(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            identityKeys: [provider.id: "acct-b"]
        )

        XCTAssertNil(store.localSnapshots[provider.id],
                     "the previous account's snapshot must not survive behind the unchanged card id")
        XCTAssertFalse(store.data(for: descriptor).hasData,
                       "the persisted cache, stamped by the old account, must not repaint either")
    }

    func testAFetchFinishingAfterACatalogSwapIsDiscardedAndNotStamped() async throws {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let cache = ProviderSnapshotCache(userDefaults: makeUserDefaults("mid-fetch-swap"), storageKey: "snapshots")
        let oldRuntime = BlockingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 11, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [oldRuntime],
            cache: cache,
            providerIdentityKeys: [provider.id: "acct-a"]
        )

        oldRuntime.blockNextRefresh = true
        let inFlight = Task { await store.refresh(providerID: provider.id, force: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !oldRuntime.isWaiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard oldRuntime.isWaiting else {
            inFlight.cancel()
            return XCTFail("the old account's refresh did not enter the in-flight state")
        }

        let newRuntime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        store.replaceProviderCatalog(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [newRuntime],
            identityKeys: [provider.id: "acct-b"]
        )
        oldRuntime.resume()
        let outcome = await inFlight.value

        guard case .skipped = outcome else {
            return XCTFail("a fetch crossing a catalog swap must be discarded, got \(outcome)")
        }
        XCTAssertNil(store.localSnapshots[provider.id], "the old account's late result must not publish")
        XCTAssertTrue(cache.loadSnapshots(providerIDs: [provider.id]).isEmpty,
                      "the late result must never be stamped with the new account's identity")
    }

    func testNewAccountFetchFailureShowsAnErrorInsteadOfTheOldAccountsData() async {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let cache = ProviderSnapshotCache(userDefaults: makeUserDefaults("new-account-failure"), storageKey: "snapshots")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            providerIdentityKeys: [provider.id: "acct-a"]
        )
        _ = await store.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(store.data(for: descriptor).used, 40)

        runtime.snapshot = ProviderSnapshot.error(provider: provider, message: "Not signed in")
        store.replaceProviderCatalog(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            identityKeys: [provider.id: "acct-b"]
        )
        let outcome = await store.refresh(providerID: provider.id, force: true)

        guard case .failed = outcome else {
            return XCTFail("expected the new account's refresh to fail, got \(outcome)")
        }
        XCTAssertEqual(store.errorMessage(for: provider.id), "Not signed in")
        XCTAssertFalse(store.data(for: descriptor).hasData,
                       "the previous account's values must not stand in for the failed new account")
    }

    func testReplacingProviderCatalogMakesANewAccountCardRefreshableWithoutRestart() async {
        let defaultProvider = Self.testProvider
        let defaultDescriptor = Self.descriptor(defaultProvider, id: "test.alpha", metric: "Alpha")
        let accountProvider = Provider(id: "codex@work", displayName: "Codex — Work", icon: .providerMark("codex"))
        let accountDescriptor = Self.descriptor(accountProvider, id: "codex@work.weekly", metric: "Weekly")
        let defaultRuntime = MutableProviderRuntime(
            provider: defaultProvider,
            descriptors: [defaultDescriptor],
            snapshot: ProviderSnapshot(providerID: defaultProvider.id, displayName: defaultProvider.displayName, lines: [])
        )
        let accountRuntime = MutableProviderRuntime(
            provider: accountProvider,
            descriptors: [accountDescriptor],
            snapshot: ProviderSnapshot(
                providerID: accountProvider.id,
                displayName: accountProvider.displayName,
                lines: [.progress(label: "Weekly", used: 43, limit: 100, format: .percent)]
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [defaultProvider], descriptors: [defaultDescriptor]),
            providers: [defaultRuntime],
            cache: ProviderSnapshotCache(userDefaults: makeUserDefaults("runtime-account-card"), storageKey: "snapshots")
        )

        store.replaceProviderCatalog(
            registry: WidgetRegistry(
                providers: [defaultProvider, accountProvider],
                descriptors: [defaultDescriptor, accountDescriptor]
            ),
            providers: [defaultRuntime, accountRuntime],
            identityKeys: [accountProvider.id: "work"]
        )
        await store.refreshAfterAccountSelection(providerID: accountProvider.id, maxAttempts: 1)

        XCTAssertEqual(store.knownProviderIDs, [defaultProvider.id, accountProvider.id])
        XCTAssertEqual(store.data(for: accountDescriptor).used, 43)
    }

    func testCompletedEmptyHistoryStillClearsLastGoodHistory() async throws {
        let provider = Self.testProvider
        let descriptor = Self.descriptor(provider, id: "test.alpha", metric: "Alpha")
        let defaults = makeUserDefaults("completed-empty-history")
        let runtime = MutableProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                plan: "With history",
                lines: [.progress(label: "Alpha", used: 40, limit: 100, format: .percent)],
                usageHistory: ProviderUsageHistory(
                    series: DailyUsageSeries(daily: [
                        DailyUsageEntry(date: "2026-07-17", totalTokens: 400, costUSD: 4)
                    ])
                )
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
        _ = await store.refresh(providerID: provider.id, force: true)

        runtime.snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            plan: "Completed empty scan",
            lines: [.progress(label: "Alpha", used: 50, limit: 100, format: .percent)],
            usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        )
        _ = await store.refresh(providerID: provider.id, force: true)

        let refreshed = try XCTUnwrap(store.localSnapshots[provider.id])
        XCTAssertEqual(refreshed.plan, "Completed empty scan")
        XCTAssertEqual(refreshed.usageHistory?.series.daily, [])
    }

    // MARK: - Fixtures

    private static let testProvider = Provider(
        id: "test",
        displayName: "Test",
        icon: .providerMark("cursor")
    )

    private static func descriptor(_ provider: Provider, id: String, metric: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metric,
            sample: WidgetData(
                title: metric,
                icon: provider.icon,
                kind: .percent,
                used: 10,
                limit: 100
            )
        )
    }

    func testCorruptCacheBlobRecoversToEmptyInsteadOfDroppingSilently() {
        let defaults = makeUserDefaults("corrupt-cache")
        defaults.set(Data("not a valid snapshot payload".utf8), forKey: "snapshots")
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })

        let loaded = cache.loadSnapshots(providerIDs: ["test.alpha"])

        XCTAssertTrue(loaded.isEmpty)
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.StaleWhileRevalidate.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class MutableProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var snapshot: ProviderSnapshot

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        snapshot
    }
}

@MainActor
private final class BlockingProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var snapshot: ProviderSnapshot
    var blockNextRefresh = false
    private(set) var isWaiting = false
    private(set) var refreshCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot {
        refreshCount += 1
        if blockNextRefresh {
            blockNextRefresh = false
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
            isWaiting = false
        }
        return snapshot
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
