import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreClaimRefreshTests: XCTestCase {
    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        let snapshot: ProviderSnapshot
        var refreshCount = 0
        var beforeRefresh: (() async -> Void)?

        init(id: String = "codex", used: Double) {
            provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
            snapshot = ProviderSnapshot(
                providerID: id, displayName: id.capitalized,
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)]
            )
        }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            await beforeRefresh?()
            return snapshot
        }
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeStore(providers: [Runtime], identityKeys: [String: String]) -> WidgetDataStore {
        let suite = "WidgetDataStoreClaimRefreshTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults, providerIdentityKeys: identityKeys
        )
    }

    func testUnrelatedAccountChangeRetriesPostClaimRefreshForTheSameIdentity() async {
        let started = expectation(description: "post-claim refresh started")
        let gate = Gate()
        let old = Runtime(used: 90)
        old.beforeRefresh = { started.fulfill(); await gate.wait() }
        let other = Runtime(id: "claude", used: 80)
        let store = makeStore(providers: [old, other], identityKeys: ["codex": "account-A", "claude": "account-C"])
        let refresh = Task { await store.refreshAfterClaim(providerID: "codex", maxAttempts: 2, retryDelay: .zero) }
        await fulfillment(of: [started], timeout: 2)
        let current = Runtime(used: 0)
        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([current, other]), providers: [current, other],
            identityKeys: ["codex": "account-A", "claude": "account-D"]
        )
        await gate.open()
        await refresh.value
        XCTAssertEqual(old.refreshCount, 1)
        XCTAssertEqual(current.refreshCount, 1, "post-claim refresh must retry after an unrelated account change")
        XCTAssertEqual(store.localSnapshots["codex"]?.lines, current.snapshot.lines)
    }

    func testReplacementAccountDoesNotReceiveThePreviousAccountsPostClaimRefresh() async {
        await assertPostClaimRefreshStops(initialIdentity: "account-A", replacementIdentity: "account-B")
    }

    func testUnresolvedIdentityDoesNotCrossACatalogChange() async {
        await assertPostClaimRefreshStops(initialIdentity: nil, replacementIdentity: nil)
    }

    private func assertPostClaimRefreshStops(initialIdentity: String?, replacementIdentity: String?) async {
        let started = expectation(description: "post-claim refresh started")
        let gate = Gate()
        let old = Runtime(used: 90)
        old.beforeRefresh = { started.fulfill(); await gate.wait() }
        let store = makeStore(providers: [old], identityKeys: initialIdentity.map { ["codex": $0] } ?? [:])
        let refresh = Task { await store.refreshAfterClaim(providerID: "codex", maxAttempts: 2, retryDelay: .zero) }
        await fulfillment(of: [started], timeout: 2)
        let current = Runtime(used: 0)
        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([current]), providers: [current],
            identityKeys: replacementIdentity.map { ["codex": $0] } ?? [:]
        )
        await gate.open()
        await refresh.value
        XCTAssertEqual(current.refreshCount, 0, "an old claim must not refresh a replacement or unresolved account")
        XCTAssertNil(store.localSnapshots["codex"])
    }
}
