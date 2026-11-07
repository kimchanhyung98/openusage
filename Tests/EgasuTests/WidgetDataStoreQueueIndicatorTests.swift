import XCTest
@testable import Egasu

@MainActor
final class WidgetDataStoreQueueIndicatorTests: XCTestCase {
    func testBatchIndicatorUsesCacheBackoffAndSuspensionRulesWithForceOverrides() async throws {
        for state in ["cached", "backoff", "suspended"] {
            for force in [false, true] {
                let queue = BackgroundWorkQueue()
                let suite = "WidgetDataStoreQueueIndicatorTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let first = Runtime(provider: MockData.cursor)
                let second = Runtime(provider: MockData.codex)
                let cache = ProviderSnapshotCache(userDefaults: defaults)
                let store = WidgetDataStore(
                    registry: .from([first, second]), providers: [first, second],
                    cache: cache, defaults: defaults, workQueue: queue
                )
                if state == "cached" {
                    let result = await store.refresh(providerID: "codex", force: true)
                    XCTAssertEqual(result, .refreshed)
                } else if state == "backoff" {
                    second.shouldFail = true
                    let result = await store.refresh(providerID: "codex", force: true)
                    XCTAssertEqual(result, .failed)
                } else {
                    store.isRefreshSuspended = { $0 == "codex" }
                }
                let previousCalls = second.calls
                let acquired = await queue.acquire("test:block-batch")
                let ticket = try XCTUnwrap(acquired)
                defer { queue.finish(ticket) }
                let batch = Task { await store.refreshAll(force: force) }
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while queue.pendingCount == 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                }
                guard queue.pendingCount == 1 else {
                    batch.cancel()
                    queue.finish(ticket)
                    await batch.value
                    return XCTFail("the first batch provider did not enter the queue")
                }
                let expectedQueued = force && state != "suspended"
                XCTAssertTrue(store.isRefreshQueued(for: "cursor"))
                XCTAssertEqual(store.isRefreshQueued(for: "codex"), expectedQueued,
                               "state=\(state), force=\(force)")
                XCTAssertEqual(second.calls, previousCalls)

                queue.finish(ticket)
                await batch.value
                XCTAssertEqual(first.calls, 1)
                XCTAssertEqual(second.calls, previousCalls + (expectedQueued ? 1 : 0))
                XCTAssertFalse(store.isRefreshQueued(for: "codex"))
                if state == "cached", !force {
                    let snapshot = try XCTUnwrap(cache.snapshot(providerID: "codex"))
                    XCTAssertEqual(store.scheduledRefreshDate(for: "codex"),
                                   snapshot.freshnessDate.addingTimeInterval(RefreshSetting.interval(for: "codex")))
                }
            }
        }
    }

    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        var shouldFail = false
        var calls = 0

        init(provider: Provider) { self.provider = provider }
        func hasLocalCredentials() async -> Bool { false }

        func refresh() async -> ProviderSnapshot {
            calls += 1
            if shouldFail { return .error(provider: provider, message: "Unavailable", category: .network) }
            return .make(provider: provider, plan: nil, lines: [], refreshedAt: .now)
        }
    }
}
