import XCTest
@testable import OpenUsage

@MainActor
final class SplitRefreshCadenceTests: XCTestCase {
    func testGeneralLoopContinuesWhileClaudeRequestIsSuspended() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let claudeStarted = expectation(description: "Claude suspended")
        let firstGeneral = expectation(description: "First general refresh")
        let secondGeneral = expectation(description: "Second general refresh")
        var continuation: CheckedContinuation<Void, Never>?
        fixture.claude.beforeRefresh = {
            await withCheckedContinuation { continuation = $0; claudeStarted.fulfill() }
        }
        fixture.store.onFreshSnapshot = { snapshot, _, _ in
            if snapshot.providerID == "codex" {
                (fixture.codex.refreshCount == 1 ? firstGeneral : secondGeneral).fulfill()
            }
        }
        let center = NotificationCenter()
        let telemetry = TelemetryRecorder(sink: Sink(), store: TelemetryStore(defaults: fixture.defaults), snapshot: {
            TelemetryConfigSnapshot(enabledProviders: [], enabledMetricIDs: [], pinnedMetricIDs: [],
                                    expandedMetricIDs: [], menuBarStyle: "text")
        })
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
        let loop = AppRefreshLoop.start(
            dataStore: fixture.store, providerStatus: ProviderStatusStore(http: http), telemetry: telemetry,
            enabledProviderIDs: { [] }, reconcileAccounts: {}, wakeSignal: RefreshWakeSignal(center: center),
            claudeWakeSignal: RefreshWakeSignal(center: center), now: { fixture.time }
        )
        await fulfillment(of: [claudeStarted, firstGeneral], timeout: 2)
        XCTAssertNil(fixture.store.nextScheduledRefresh(for: .claude, at: fixture.time))
        fixture.time = fixture.start.addingTimeInterval(300)
        center.post(name: ProviderEnablementStore.didChangeNotification, object: nil)
        await fulfillment(of: [secondGeneral], timeout: 2)
        XCTAssertEqual(fixture.counts, [2, 1])
        loop.cancel()
        continuation?.resume()
        await loop.value
    }

    private final class Sink: TelemetrySink {
        func capture(_ event: String, _ properties: [String: Any]) {}
        func setEnabled(_ enabled: Bool) {}
        func flush() {}
    }

    func testBackwardClockChangeRechecksBothCadences() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.store.refreshAll()
        let entered = expectation(description: "Initial loop pass")
        let regular = expectation(description: "General refreshed after clock change")
        let claude = expectation(description: "Claude refreshed after clock change")
        fixture.store.onFreshSnapshot = { snapshot, _, _ in
            (snapshot.providerID == "codex" ? regular : claude).fulfill()
        }
        let center = NotificationCenter()
        let telemetry = TelemetryRecorder(sink: Sink(), store: TelemetryStore(defaults: fixture.defaults), snapshot: {
            TelemetryConfigSnapshot(enabledProviders: [], enabledMetricIDs: [], pinnedMetricIDs: [],
                                    expandedMetricIDs: [], menuBarStyle: "text")
        })
        var passes = 0
        let loop = AppRefreshLoop.start(
            dataStore: fixture.store,
            providerStatus: ProviderStatusStore(http: FakeHTTPClient(
                response: HTTPResponse(statusCode: 503, headers: [:], body: Data())
            )), telemetry: telemetry, enabledProviderIDs: { [] },
            reconcileAccounts: { passes += 1; if passes == 1 { entered.fulfill() } },
            wakeSignal: RefreshWakeSignal(center: center),
            claudeWakeSignal: RefreshWakeSignal(center: center), now: { fixture.time }
        )
        await fulfillment(of: [entered], timeout: 2)
        fixture.time = fixture.start.addingTimeInterval(-3600)
        center.post(name: .NSSystemClockDidChange, object: nil)
        await fulfillment(of: [regular, claude], timeout: 2)
        loop.cancel()
        await loop.value
        XCTAssertEqual(fixture.counts, [2, 2])
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "codex"), fixture.time.addingTimeInterval(300))
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "claude@work"), fixture.time.addingTimeInterval(900))
        XCTAssertLessThanOrEqual(fixture.store.nextGeneralRefreshAt ?? .distantFuture, fixture.time.addingTimeInterval(300))
    }

    func testInvalidatedRequestWakesCadenceAfterReenable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let started = expectation(description: "Old Claude request started")
        var continuation: CheckedContinuation<Void, Never>?
        fixture.claude.beforeRefresh = { await withCheckedContinuation { continuation = $0; started.fulfill() } }
        let task = Task { await fixture.store.refreshAll(cadence: .claude) }
        await fulfillment(of: [started], timeout: 2)
        fixture.disabled.insert("claude@work")
        fixture.store.providerEnablementDidChange()
        fixture.disabled.removeAll()
        fixture.store.clearFailureBackoff(for: "claude@work")
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertNil(fixture.store.nextScheduledRefresh(for: .claude, at: fixture.time))
        let resumed = expectation(forNotification: WidgetDataStore.refreshScheduleDidChange, object: nil)
        continuation?.resume()
        await task.value
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.isEmpty)
        XCTAssertNil(fixture.store.snapshots["claude@work"])
        XCTAssertEqual(fixture.store.nextScheduledRefresh(for: .claude, at: fixture.time), fixture.time)
        fixture.claude.beforeRefresh = {}
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.claude.refreshCount, 2)
        XCTAssertNotNil(fixture.store.snapshots["claude@work"])
    }

    func testSeparateCadencesManualRefreshAndWakeDoNotCreateExtraRequests() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        await fixture.store.refreshAll(cadence: .regular)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.counts, [1, 1])
        fixture.time = fixture.start.addingTimeInterval(300)
        await fixture.store.refreshAll(cadence: .regular)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.counts, [2, 1])
        let claudeDue = fixture.store.scheduledRefreshDate(for: "claude@work")
        fixture.time = fixture.start.addingTimeInterval(400)
        await fixture.store.refresh(providerID: "codex", force: true, trigger: .manual)
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "claude@work"), claudeDue)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.counts, [3, 1])
        fixture.time = fixture.start.addingTimeInterval(900)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.counts, [3, 2])
        fixture.time = fixture.start.addingTimeInterval(10_000)
        await fixture.store.refreshAll(cadence: .claude)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.counts, [3, 3])
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "claude@work"), fixture.time.addingTimeInterval(900))
    }

    func testDisabledLateResultIsDiscardedAndRefetchesAfterReenable() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let started = expectation(description: "Claude started")
        var continuation: CheckedContinuation<Void, Never>?
        fixture.claude.beforeRefresh = { await withCheckedContinuation { continuation = $0; started.fulfill() } }
        let task = Task { await fixture.store.refreshAll(cadence: .claude) }
        await fulfillment(of: [started], timeout: 2)
        fixture.disabled.insert("claude@work")
        fixture.store.providerEnablementDidChange()
        continuation?.resume()
        await task.value
        XCTAssertNil(fixture.store.snapshots["claude@work"])
        XCTAssertNil(fixture.store.nextScheduledRefresh(for: .claude, at: fixture.time))
        fixture.claude.beforeRefresh = {}
        fixture.disabled.removeAll()
        fixture.store.clearFailureBackoff(for: "claude@work")
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.claude.refreshCount, 2)
        XCTAssertNotNil(fixture.store.snapshots["claude@work"])
    }

    func testCooldownWinsOverCadenceAndOldQuotaRemainsStale() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.claude.retryAfter = fixture.start.addingTimeInterval(3600)
        fixture.claude.quotaObservedAt = fixture.start.addingTimeInterval(-1800)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "claude@work"), fixture.start.addingTimeInterval(3600))
        XCTAssertNotNil(fixture.store.stalenessHint(for: "claude@work"))
        fixture.time = fixture.start.addingTimeInterval(900)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.claude.refreshCount, 1)
    }

    func testClockChangeBoundsLocalFailureWaitButPreservesClaudeCooldown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.codex.fails = true
        fixture.claude.retryAfter = fixture.start.addingTimeInterval(3600)
        await fixture.store.refreshAll()
        fixture.time = fixture.start.addingTimeInterval(-3600)
        fixture.store.rebaseRefreshSchedule(for: .regular, at: fixture.time)
        fixture.store.rebaseRefreshSchedule(for: .claude, at: fixture.time)
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "codex"), fixture.time.addingTimeInterval(60))
        XCTAssertEqual(fixture.store.scheduledRefreshDate(for: "claude@work"), fixture.claude.retryAfter)
        await fixture.store.refreshAll(cadence: .regular)
        await fixture.store.refreshAll(cadence: .claude)
        XCTAssertEqual(fixture.counts, [1, 1])
        fixture.time = fixture.time.addingTimeInterval(61)
        fixture.codex.fails = false
        await fixture.store.refreshAll(cadence: .regular)
        XCTAssertEqual(fixture.counts, [2, 1])
    }

    func testSuspendedWorkDoesNotProducePastDeadlines() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.isRefreshSuspended = { _ in true }
        XCTAssertNil(fixture.store.nextScheduledRefresh(for: .regular, at: fixture.time))
        await fixture.store.refreshAll(cadence: .regular)
        XCTAssertEqual(fixture.codex.refreshCount, 0)
    }

    @MainActor
    private final class Fixture {
        let suite = "OpenUsageTests.SplitCadence.\(UUID().uuidString)"
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var time: Date
        let defaults: UserDefaults
        let codex = Runtime(id: "codex")
        let claude = Runtime(id: "claude@work")
        var disabled = Set<String>()
        lazy var store = WidgetDataStore(
            registry: WidgetRegistry(providers: [codex.provider, claude.provider], descriptors: []),
            providers: [codex, claude],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { self.time }), defaults: defaults,
            isProviderEnabled: { !self.disabled.contains($0) }, now: { self.time }
        )
        var counts: [Int] { [codex.refreshCount, claude.refreshCount] }
        init() throws {
            time = start
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            codex.now = { [unowned self] in self.time }
            claude.now = { [unowned self] in self.time }
        }
        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        var refreshCount = 0
        var now: () -> Date = Date.init
        var retryAfter: Date?
        var quotaObservedAt: Date?
        var fails = false
        var beforeRefresh: () async -> Void = {}
        init(id: String) { provider = Provider(id: id, displayName: id, icon: .providerMark("claude")) }
        func hasLocalCredentials() async -> Bool { false }
        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            await beforeRefresh()
            if fails { return .error(provider: provider, message: "Request failed", category: .network) }
            return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [],
                                    refreshedAt: now(), quotaObservedAt: quotaObservedAt, usageRetryAfter: retryAfter)
        }
    }
}
