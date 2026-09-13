import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreDeadlineTests: XCTestCase {
    func testTimeoutPreservesLastGoodAndBlocksOverlapUntilLateWorkFinishes() async {
        let runtime = Runtime()
        let fixture = makeStore([runtime])
        let store = fixture.store
        await store.refresh(providerID: "codex", force: true)
        let lastGood = store.localSnapshots["codex"]
        let recorder = Recorder(store)
        let started = expectation(description: "Slow refresh started")
        let finished = expectation(description: "Late refresh finished")
        let gate = Gate()
        runtime.beforeRefresh = { started.fulfill(); await gate.wait(); finished.fulfill() }
        runtime.snapshot.plan = "Late result"
        let task = Task { await store.refresh(providerID: "codex", force: true, trigger: .manual) }
        await fulfillment(of: [started], timeout: 2)
        let outcome = await task.value
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
        XCTAssertEqual(store.localSnapshots["codex"], lastGood)
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"], lastGood)
        XCTAssertEqual(store.refreshResults["codex"]?.failure?.category, .network)
        XCTAssertNil(store.refreshResults["codex"]?.failure?.authenticationIssue)
        let status = store.accountStatus(for: "codex", localState: .ready(identityKey: "account-A", label: nil))
        XCTAssertEqual(status.title, "Refresh Failed")
        XCTAssertTrue(status.canSwitch)
        XCTAssertEqual(recorder.outcomes, [.failed])
        XCTAssertEqual(recorder.categories, [.network])
        XCTAssertEqual(recorder.triggers, [.manual])
        XCTAssertEqual(recorder.freshSnapshots, 0)
        XCTAssertEqual(recorder.historyChanges, 0)
        let overlap = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(overlap, .skipped)
        XCTAssertEqual(runtime.refreshCount, 2)
        gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(store.localSnapshots["codex"], lastGood)
        XCTAssertEqual(recorder.outcomes, [.failed])
        let cached = await store.refresh(providerID: "codex")
        XCTAssertEqual(cached, .cacheHit)
        XCTAssertNotNil(store.refreshResults["codex"]?.failure, "Cache hits do not prove recovery")
        runtime.beforeRefresh = {}
        let recovered = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(recovered, .refreshed)
        XCTAssertNil(store.refreshResults["codex"]?.failure)
        XCTAssertEqual(recorder.freshSnapshots, 1)
        XCTAssertEqual(runtime.manualContexts, [true, true, true])
    }

    func testTimeoutUsesFailureBackoffAndScheduledRefreshRecoversAfterExpiry() async {
        let runtime = Runtime()
        let finished = expectation(description: "Cancelled provider finished")
        runtime.beforeRefresh = { try? await Task.sleep(for: .seconds(60)); finished.fulfill() }
        let fixture = makeStore([runtime])
        let recorder = Recorder(fixture.store)
        let failed = await fixture.store.refresh(providerID: "codex")
        XCTAssertEqual(failed, .failed)
        let backedOff = await fixture.store.refresh(providerID: "codex")
        XCTAssertEqual(backedOff, .backedOff)
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(recorder.triggers, [.scheduled])
        await fulfillment(of: [finished], timeout: 2)
        fixture.clock.date.addTimeInterval(61)
        runtime.beforeRefresh = {}
        let recovered = await fixture.store.refresh(providerID: "codex")
        XCTAssertEqual(recovered, .refreshed)
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    func testBatchCompletesAfterTimeoutAndSyncsOnlySuccessfulHistory() async {
        let slow = Runtime()
        let fast = Runtime(id: "claude")
        let fixture = makeStore([slow, fast])
        let recorder = Recorder(fixture.store)
        let finished = expectation(description: "Late work finished")
        let gate = Gate()
        slow.beforeRefresh = { await gate.wait(); finished.fulfill() }
        await fixture.store.refreshAll(force: true)
        XCTAssertNotNil(fixture.store.lastRefreshAt)
        XCTAssertTrue(fixture.store.refreshingProviderIDs.isEmpty)
        XCTAssertNotNil(fixture.store.localSnapshots["claude"])
        XCTAssertNil(fixture.store.localSnapshots["codex"])
        XCTAssertEqual(recorder.outcomes.filter { $0 == .failed }.count, 1)
        XCTAssertEqual(recorder.outcomes.filter { $0 == .refreshed }.count, 1)
        XCTAssertEqual(recorder.historyChanges, 1)
        XCTAssertEqual(recorder.freshSnapshots, 1)
        gate.open()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertNil(fixture.store.localSnapshots["codex"])
        XCTAssertEqual(recorder.historyChanges, 1)
    }

    func testCancellationStopsTheBatchWithoutWaitingForHungWorkOrPublishingLateResults() async {
        let slow = Runtime()
        let fast = Runtime(id: "claude")
        let fixture = makeStore([slow, fast], timeout: 60)
        let recorder = Recorder(fixture.store)
        let started = expectation(description: "Slow refresh started")
        let fastFinished = expectation(description: "Fast card published")
        let workCancelled = expectation(description: "Slow work cancelled")
        let lateFinished = expectation(description: "Late work finished")
        let gate = Gate()
        slow.beforeRefresh = {
            await withTaskCancellationHandler {
                started.fulfill()
                await gate.wait()
                lateFinished.fulfill()
            } onCancel: { workCancelled.fulfill() }
        }
        fixture.store.onFreshSnapshot = { snapshot, _ in
            if snapshot.providerID == "claude" { fastFinished.fulfill() }
            else { XCTFail("Cancelled Codex snapshot must not reach quota observation") }
        }
        let batchFinished = expectation(description: "Cancelled batch returned")
        let task = Task {
            await fixture.store.refreshAll(force: true)
            batchFinished.fulfill()
        }
        await fulfillment(of: [started, fastFinished], timeout: 2)
        XCTAssertNotNil(fixture.store.localSnapshots["claude"])
        task.cancel()
        await fulfillment(of: [batchFinished, workCancelled], timeout: 2)
        await task.value
        XCTAssertNil(fixture.store.lastRefreshAt)
        XCTAssertEqual(recorder.historyChanges, 0)
        XCTAssertEqual(recorder.outcomes, [.refreshed])
        XCTAssertTrue(fixture.store.refreshingProviderIDs.isEmpty)
        XCTAssertNil(fixture.store.localSnapshots["codex"])
        XCTAssertNil(fixture.store.refreshResults["codex"])
        gate.open()
        await fulfillment(of: [lateFinished], timeout: 2)
        XCTAssertNil(fixture.store.localSnapshots["codex"])
        XCTAssertNil(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"])
    }

    func testTimeoutDoesNotPublishAcrossCatalogAuthenticationOrCredentialChanges() async {
        for boundary in ["catalog", "authentication", "credentials"] {
            let runtime = Runtime()
            let fixture = makeStore([runtime])
            await fixture.store.refresh(providerID: "codex", force: true)
            let recorder = Recorder(fixture.store)
            let started = expectation(description: "Refresh started before \(boundary)")
            let finished = expectation(description: "Old work finished")
            let gate = Gate()
            runtime.beforeRefresh = { started.fulfill(); await gate.wait(); finished.fulfill() }
            let task = Task { await fixture.store.refresh(providerID: "codex", force: true) }
            await fulfillment(of: [started], timeout: 2)
            switch boundary {
            case "catalog":
                fixture.store.replaceProviderCatalog(
                    registry: .from([runtime]), providers: [runtime], identityKeys: ["codex": "account-B"]
                )
            case "authentication": fixture.store.invalidateAuthentication(for: "codex")
            default: _ = fixture.store.credentialsDidChange(for: "codex")
            }
            let outcome = await task.value
            XCTAssertEqual(outcome, .skipped, boundary)
            XCTAssertNil(fixture.store.refreshResults["codex"]?.failure, boundary)
            XCTAssertTrue(recorder.outcomes.isEmpty, boundary)
            XCTAssertEqual(recorder.freshSnapshots, 0, boundary)
            XCTAssertGreaterThan(recorder.quotaInvalidations, 0, boundary)
            gate.open()
            await fulfillment(of: [finished], timeout: 2)
            runtime.beforeRefresh = {}
            let recovered = await fixture.store.refresh(providerID: "codex")
            XCTAssertEqual(recovered, .refreshed, "\(boundary) must require new credentials, not a cache hit")
            XCTAssertEqual(recorder.freshSnapshots, 1)
        }
    }

    func testSuccessfulResetClaimDoesNotRepeatPOSTWhenRefreshTimesOutThreeTimes() async {
        let runtime = Runtime()
        runtime.beforeRefresh = { try? await Task.sleep(for: .seconds(60)) }
        let fixture = makeStore([runtime])
        let recorder = Recorder(fixture.store)
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {"credits":[{"id":"RateLimitResetCredit_test","status":"available","expires_at":"\(OpenUsageISO8601.string(from: expiry))"}],"available_count":1}
                """.utf8))
            }
            XCTAssertEqual(request.url, CodexUsageClient.consumeResetCreditURL)
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset","windows_reset":2}"#.utf8))
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialCandidates: { [("test-token", "test-account")] },
            refreshAfterClaim: {
                await fixture.store.refreshAfterClaim(providerID: "codex", retryDelay: .milliseconds(1))
            }
        )
        let outcome = await service.claim(creditExpiringAt: expiry, redeemRequestID: "test-request")
        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(http.requests.filter { $0.method == "POST" }.count, 1)
        XCTAssertEqual(runtime.refreshCount, 3)
        XCTAssertEqual(recorder.outcomes, [.failed, .failed, .failed])
        XCTAssertEqual(recorder.triggers, [.resetClaim, .resetClaim, .resetClaim])
    }

    private func makeStore(_ runtimes: [Runtime], timeout: TimeInterval = 0.05) -> Fixture {
        let suite = "WidgetDataStoreDeadlineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let clock = Clock()
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { clock.date })
        let store = WidgetDataStore(
            registry: .from(runtimes), providers: runtimes, cache: cache, defaults: defaults,
            now: { clock.date }, providerRefreshTimeout: timeout, providerIdentityKeys: ["codex": "account-A"]
        )
        return Fixture(store: store, cache: cache, clock: clock)
    }

    private struct Fixture {
        let store: WidgetDataStore
        let cache: ProviderSnapshotCache
        let clock: Clock
    }

    private final class Clock { var date = Date() }

    @MainActor
    private final class Recorder {
        var outcomes: [WidgetDataStore.RefreshOutcome] = []
        var categories: [ErrorCategory?] = []
        var triggers: [RefreshTrigger] = []
        var freshSnapshots = 0
        var historyChanges = 0
        var quotaInvalidations = 0
        init(_ store: WidgetDataStore) {
            store.onRefreshOutcome = { [self] _, outcome, category, trigger, _ in
                outcomes.append(outcome); categories.append(category); triggers.append(trigger)
            }
            store.onFreshSnapshot = { [self] _, _ in freshSnapshots += 1 }
            store.onLocalHistoryChanged = { [self] in historyChanges += 1 }
            store.onQuotaInvalidated = { [self] in quotaInvalidations += 1 }
        }
    }

    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        var snapshot: ProviderSnapshot
        var refreshCount = 0
        var manualContexts: [Bool] = []
        var beforeRefresh: @MainActor () async -> Void = {}
        init(id: String = "codex") {
            provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
            snapshot = ProviderSnapshot(
                providerID: id, displayName: id.capitalized,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                usageHistory: ProviderUsageHistory(series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2026-09-13", totalTokens: 42, costUSD: 3)
                ]))
            )
        }
        func hasLocalCredentials() async -> Bool { true }
        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            manualContexts.append(ProviderRefreshContext.isManual)
            let result = snapshot
            await beforeRefresh()
            return result
        }
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
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
}
