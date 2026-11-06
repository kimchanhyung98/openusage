import XCTest
@testable import OpenUsage

@MainActor
final class BackgroundWorkQueueTests: XCTestCase {
    func testWaitingCancellationReturnsBeforeActiveWorkFinishesAndPreservesFIFO() async throws {
        let queue = BackgroundWorkQueue()
        let acquired = await queue.acquire("active")
        let active = try XCTUnwrap(acquired)
        var order: [String] = []
        let first = Task { await queue.run("first") { order.append("first") } }
        await waitForPending(1, in: queue)
        let cancelled = Task { await queue.run("cancelled") { XCTFail("Cancelled work must not start") } }
        await waitForPending(2, in: queue)
        let last = Task { await queue.run("last") { order.append("last") } }
        await waitForPending(3, in: queue)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertTrue(order.isEmpty)
        XCTAssertEqual(queue.pendingCount, 2)
        queue.finish(active)
        await first.value
        await last.value
        XCTAssertEqual(order, ["first", "last"])
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testThrownOperationReleasesQueueAndPrecancelledOperationDoesNotRun() async throws {
        enum Failure: Error { case expected }
        let queue = BackgroundWorkQueue()
        do {
            let _: Void? = try await queue.run("failure") { throw Failure.expected }
            XCTFail("Expected operation failure")
        } catch Failure.expected {
        }
        let completed = await queue.run("next") { 42 }
        XCTAssertEqual(completed, 42)
        let task = Task {
            await queue.run("cancelled-before-entry") { XCTFail("Cancelled work must not start") }
        }
        task.cancel()
        let result: Void? = await task.value
        XCTAssertNil(result)
    }

    func testQueueWaitingDoesNotConsumeProviderDeadline() async throws {
        let queue = BackgroundWorkQueue()
        let acquired = await queue.acquire("blocker")
        let ticket = try XCTUnwrap(acquired)
        let runtime = Runtime()
        let suite = "BackgroundWorkQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults,
            providerRefreshTimeout: 0.02, workQueue: queue
        )
        let refresh = Task { await store.refresh(providerID: "cursor", force: true) }
        await waitForPending(1, in: queue)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(runtime.calls, 0)
        XCTAssertTrue(store.isRefreshQueued(for: "cursor"))
        XCTAssertNil(store.refreshResults["cursor"])
        queue.finish(ticket)
        let result = await refresh.value
        XCTAssertEqual(result, .refreshed)
        XCTAssertEqual(runtime.calls, 1)
        XCTAssertFalse(store.isRefreshQueued(for: "cursor"))
    }

    func testBatchShowsWaitingProvidersUntilTheirActualRefreshStarts() async throws {
        let queue = BackgroundWorkQueue()
        let acquired = await queue.acquire("blocker")
        let ticket = try XCTUnwrap(acquired)
        let first = Runtime()
        let second = Runtime(provider: MockData.codex)
        let suite = "BackgroundWorkQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: .from([first, second]), providers: [first, second],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, workQueue: queue
        )
        let firstStarted = expectation(description: "First provider starts")
        let secondStarted = expectation(description: "Second provider starts")
        let releaseFirst = Gate()
        let releaseSecond = Gate()
        defer { releaseFirst.open(); releaseSecond.open(); queue.finish(ticket) }
        first.beforeRefresh = { firstStarted.fulfill(); await releaseFirst.wait() }
        second.beforeRefresh = { secondStarted.fulfill(); await releaseSecond.wait() }
        let batch = Task { await store.refreshAll(force: true) }
        await waitForPending(1, in: queue)
        XCTAssertTrue(store.isRefreshQueued(for: "cursor"))
        XCTAssertTrue(store.isRefreshQueued(for: "codex"))

        queue.finish(ticket)
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertFalse(store.isRefreshQueued(for: "cursor"))
        XCTAssertTrue(store.refreshingProviderIDs.contains("cursor"))
        XCTAssertTrue(store.isRefreshQueued(for: "codex"))
        XCTAssertEqual(second.calls, 0)

        releaseFirst.open()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertFalse(store.isRefreshQueued(for: "cursor"))
        XCTAssertFalse(store.refreshingProviderIDs.contains("cursor"))
        XCTAssertFalse(store.isRefreshQueued(for: "codex"))
        XCTAssertTrue(store.refreshingProviderIDs.contains("codex"))
        releaseSecond.open()
        await batch.value
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
        XCTAssertFalse(store.isRefreshQueued(for: "codex"))
        XCTAssertEqual(first.calls, 1)
        XCTAssertEqual(second.calls, 1)
    }

    func testCancelledBatchClearsAllWaitingIndicatorsWithoutStartingProviders() async throws {
        let queue = BackgroundWorkQueue()
        let acquired = await queue.acquire("blocker")
        let ticket = try XCTUnwrap(acquired)
        defer { queue.finish(ticket) }
        let runtimes = [Runtime(), Runtime(provider: MockData.codex)]
        let suite = "BackgroundWorkQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: .from(runtimes), providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, workQueue: queue
        )
        let batch = Task { await store.refreshAll(force: true) }
        await waitForPending(1, in: queue)
        XCTAssertTrue(store.isRefreshQueued(for: "cursor"))
        XCTAssertTrue(store.isRefreshQueued(for: "codex"))

        batch.cancel()
        await batch.value
        XCTAssertFalse(store.isRefreshQueued(for: "cursor"))
        XCTAssertFalse(store.isRefreshQueued(for: "codex"))
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
        XCTAssertTrue(runtimes.allSatisfy { $0.calls == 0 })
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testQueuedProviderDoesNotUseRuntimeReplacedBeforeExecution() async throws {
        let queue = BackgroundWorkQueue()
        let acquired = await queue.acquire("blocker")
        let ticket = try XCTUnwrap(acquired)
        let previous = Runtime()
        let replacement = Runtime()
        let suite = "BackgroundWorkQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: .from([previous]), providers: [previous],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults, workQueue: queue
        )
        let refresh = Task { await store.refresh(providerID: "cursor", force: true) }
        await waitForPending(1, in: queue)
        store.replaceProviderCatalog(registry: .from([replacement]), providers: [replacement], identityKeys: [:])
        queue.finish(ticket)
        let result = await refresh.value
        XCTAssertEqual(result, .skipped)
        XCTAssertEqual(previous.calls, 0)
        XCTAssertEqual(replacement.calls, 0)
        XCTAssertNil(store.localSnapshots["cursor"])
    }

    func testLogCacheMaintenanceWaitsForActiveRefresh() async throws {
        let queue = BackgroundWorkQueue()
        let acquired = await queue.acquire("usage")
        let ticket = try XCTUnwrap(acquired)
        defer { queue.finish(ticket) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = JSONLScanCachePersistence(
            namespace: "queued", schemaVersion: 1,
            directory: directory.appendingPathComponent("cache"), writeDebounce: .zero
        )
        let stale = JSONLScanCachePaths.identityDirectory(persistence: persistence, identity: "stale")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-JSONLScanCachePaths.staleIdentityRetention - 60)],
            ofItemAtPath: stale.path
        )
        let file = directory.appendingPathComponent("usage.jsonl")
        try Data("7".utf8).write(to: file)
        let metadata = try file.resourceValues(forKeys: [.contentModificationDateKey])
        let discovered = JSONLScanning.DiscoveredFile(
            path: file.path, size: 1, mtime: try XCTUnwrap(metadata.contentModificationDate)
        )
        let scanner = IncrementalJSONLScanner<Int>(persistence: persistence, workQueue: queue)
        let values = await scanner.items(from: [discovered], since: .distantPast) { _ in [7] }
        XCTAssertEqual(values, [7])
        await waitForPending(2, in: queue)
        let manifest = JSONLScanCachePaths.manifestURL(persistence: persistence, identity: "default")
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))

        queue.finish(ticket)
        await scanner.waitForPendingWritesForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.path))
        let restored = IncrementalJSONLScanner<Int>(persistence: persistence, workQueue: queue)
        let cached = await restored.items(from: [discovered], since: .distantPast) { _ in
            XCTFail("The queued write must remain reusable after completion")
            return []
        }
        XCTAssertEqual(cached, [7])
    }

    private func waitForPending(_ count: Int, in queue: BackgroundWorkQueue) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while queue.pendingCount != count, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(queue.pendingCount, count)
    }

    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        var calls = 0
        var beforeRefresh: (@MainActor () async -> Void)?
        init(provider: Provider = MockData.cursor) { self.provider = provider }
        func hasLocalCredentials() async -> Bool { false }
        func refresh() async -> ProviderSnapshot {
            calls += 1
            await beforeRefresh?()
            return .make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
        }
    }

    @MainActor
    private final class Gate {
        private var isOpen = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if !isOpen { await withCheckedContinuation { continuation = $0 } }
        }
        func open() {
            isOpen = true
            continuation?.resume()
            continuation = nil
        }
    }
}
