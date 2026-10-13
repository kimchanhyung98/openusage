import XCTest
@testable import OpenUsage

@MainActor
final class ClaudeUnresolvedHistoryTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 7, day: 16, hour: 12))!
    private let identity = "account-a|org-a"

    func testFailedUnresolvedClaudeStaysHiddenAcrossPeerUpdatesAndRecoversOnSuccess() async throws {
        for identifiedPeer in [true, false] {
            let runtime = makeRuntime()
            let store = makeStore([runtime])
            let peerIdentity = identifiedPeer ? identity : nil
            store.setPeerHistoryDocuments(
                [peerDocument(tokens: 200, cost: 2, identity: peerIdentity)], ownDeviceID: "local"
            )
            let first = await store.refresh(providerID: "claude", force: true)
            XCTAssertEqual(first, .refreshed)
            XCTAssertEqual(try todayValues(in: store), [3, 300])

            runtime.fail()
            let failed = await store.refresh(providerID: "claude", force: true)

            XCTAssertEqual(failed, .failed)
            XCTAssertNil(store.localSnapshots["claude"])
            XCTAssertNil(store.snapshots["claude"], "ambiguous peer history must not recreate the cleared card")
            XCTAssertNotNil(store.providerErrors["claude"])

            store.setPeerHistoryDocuments(
                [peerDocument(tokens: 500, cost: 5, identity: peerIdentity)], ownDeviceID: "local"
            )
            XCTAssertNil(store.snapshots["claude"], "later peer updates must keep the failed card hidden")

            runtime.snapshot = snapshot(provider: runtime.provider, tokens: 200, cost: 2)
            let recovered = await store.refresh(providerID: "claude", force: true)

            XCTAssertEqual(recovered, .refreshed)
            XCTAssertNil(store.providerErrors["claude"])
            XCTAssertEqual(try todayValues(in: store), [7, 700])
            XCTAssertEqual(store.localSnapshots["claude"]?.usageHistory, history(tokens: 200, cost: 2))
        }
    }

    func testKnownClaudeKeepsLastGoodHistoryAndPeerUpdatesAfterFailure() async throws {
        let runtime = makeRuntime()
        let store = makeStore([runtime], identities: ["claude": identity])
        store.setPeerHistoryDocuments(
            [peerDocument(tokens: 200, cost: 2, identity: identity)], ownDeviceID: "local"
        )
        await store.refresh(providerID: "claude", force: true)
        let original = store.localSnapshots["claude"]
        XCTAssertEqual(try todayValues(in: store), [3, 300])
        var notifications = 0
        store.onLocalHistoryChanged = { notifications += 1 }

        runtime.fail()
        let failed = await store.refresh(providerID: "claude", force: true)

        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(store.localSnapshots["claude"], original)
        XCTAssertEqual(try todayValues(in: store), [3, 300])
        XCTAssertEqual(notifications, 0)

        store.setPeerHistoryDocuments(
            [peerDocument(tokens: 500, cost: 5, identity: identity)], ownDeviceID: "local"
        )
        XCTAssertEqual(try todayValues(in: store), [6, 600])
    }

    func testDirectFailurePublishesHistoryRemovalOnce() async {
        let runtime = makeRuntime()
        let store = makeStore([runtime])
        await store.refresh(providerID: "claude", force: true)
        XCTAssertNotNil(store.localHistoryDocument(deviceID: "local", deviceName: "Local").providers["claude"])
        var notifications = 0
        store.onLocalHistoryChanged = { [weak store] in
            notifications += 1
            XCTAssertNil(store?.localHistoryDocument(deviceID: "local", deviceName: "Local").providers["claude"])
        }

        runtime.fail()
        let failed = await store.refresh(providerID: "claude", force: true)

        XCTAssertEqual(failed, .failed)
        XCTAssertEqual(notifications, 1)
        XCTAssertNil(store.localHistoryDocument(deviceID: "local", deviceName: "Local").providers["claude"])

        let repeatedFailure = await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(repeatedFailure, .failed)
        XCTAssertEqual(notifications, 1, "an already empty card has no further history deletion to publish")
    }

    func testAllFailedBatchPublishesHistoryRemovalOnce() async {
        for includesOtherProvider in [false, true] {
            let claude = makeRuntime()
            let runtimes = includesOtherProvider ? [claude, makeRuntime(id: "codex")] : [claude]
            let store = makeStore(runtimes, identities: ["codex": "codex-account"])
            await store.refreshAll(force: true)
            XCTAssertNotNil(store.localSnapshots["claude"]?.usageHistory)
            var notifications = 0
            store.onLocalHistoryChanged = { notifications += 1 }
            for runtime in runtimes { runtime.fail() }

            await store.refreshAll(force: true)

            XCTAssertEqual(notifications, 1, "a batch with only failures must still publish its history deletion")
            XCTAssertNil(store.localSnapshots["claude"])
            let document = store.localHistoryDocument(deviceID: "local", deviceName: "Local")
            XCTAssertNil(document.providers["claude"])
            for runtime in runtimes {
                XCTAssertNotNil(store.providerErrors[runtime.provider.id])
            }
            if includesOtherProvider {
                XCTAssertEqual(document.providers["codex"], history(tokens: 100, cost: 1))
            }

            await store.refreshAll(force: true)
            XCTAssertEqual(notifications, 1, "repeated failures without history changes must not publish again")
        }
    }

    func testMixedBatchPublishesRemovalAndSuccessTogetherOnce() async {
        let claude = makeRuntime()
        let codex = makeRuntime(id: "codex")
        let store = makeStore([claude, codex], identities: ["codex": "codex-account"])
        await store.refreshAll(force: true)
        var notifications = 0
        store.onLocalHistoryChanged = { notifications += 1 }
        claude.fail()
        codex.snapshot = snapshot(provider: codex.provider, tokens: 300, cost: 3)

        await store.refreshAll(force: true)

        XCTAssertEqual(notifications, 1)
        let document = store.localHistoryDocument(deviceID: "local", deviceName: "Local")
        XCTAssertNil(document.providers["claude"])
        XCTAssertEqual(document.providers["codex"], history(tokens: 300, cost: 3))
    }

    private func makeStore(_ runtimes: [Runtime], identities: [String: String] = [:]) -> WidgetDataStore {
        let suite = "ClaudeUnresolvedHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let date = now
        return WidgetDataStore(
            registry: .from(runtimes), providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { date }),
            defaults: defaults, now: { date }, providerIdentityKeys: identities
        )
    }

    private func makeRuntime(id: String = "claude") -> Runtime {
        let provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        return Runtime(provider: provider, snapshot: snapshot(provider: provider, tokens: 100, cost: 1))
    }

    private func snapshot(provider: Provider, tokens: Int, cost: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 40, limit: 100, format: .percent)],
            refreshedAt: now, usageHistory: history(tokens: tokens, cost: cost)
        )
    }

    private func history(tokens: Int, cost: Double) -> ProviderUsageHistory {
        ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-07-16", totalTokens: tokens, costUSD: cost)
        ]))
    }

    private func peerDocument(tokens: Int, cost: Double, identity: String?) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: "peer", deviceName: "Peer", updatedAt: now.addingTimeInterval(Double(tokens)),
            providers: ["claude": history(tokens: tokens, cost: cost)],
            identities: identity.map { ["claude": $0] }
        )
    }

    private func todayValues(in store: WidgetDataStore) throws -> [Double] {
        let snapshot = try XCTUnwrap(store.snapshots["claude"])
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Today") else {
            XCTFail("expected the combined history to produce a Today row")
            return []
        }
        return values.map(\.number)
    }

    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var snapshot: ProviderSnapshot

        init(provider: Provider, snapshot: ProviderSnapshot) {
            self.provider = provider
            self.snapshot = snapshot
            self.widgetDescriptors = [
                WidgetDescriptor.usageTrend(provider: provider)
                    .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "Test")
            ]
        }

        func refresh() async -> ProviderSnapshot { snapshot }
        func hasLocalCredentials() async -> Bool { true }

        func fail() {
            snapshot = .error(provider: provider, message: "Service unavailable", category: .network)
        }
    }
}
