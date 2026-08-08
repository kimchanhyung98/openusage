import XCTest
@testable import OpenUsage

@MainActor
final class FailureBackoffTests: XCTestCase {
    func testFailedProviderIsNotReprobedWithinBackoffWindow() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime()
        let store = makeStore(runtime: runtime, clock: { clock })

        // 첫 wake: probe 실패
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertNotNil(store.errorMessage(for: runtime.provider.id))

        // backoff window 내 연속 wake는 재probe 금지
        clock = clock.addingTimeInterval(5)
        await store.refreshAll()
        clock = clock.addingTimeInterval(5)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)

        // window 경과 후 정상 cadence로 재시도
        clock = clock.addingTimeInterval(60)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    func testManualForceRefreshBypassesFailureBackoff() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime()
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 1)

        // ⌘R / footer refresh — auth 수정 직후 즉시 재시도
        clock = clock.addingTimeInterval(1)
        await store.refreshAll(force: true)
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    func testSuccessClearsBackoffSoLaterWakesAreNotSuppressed() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        // 의도적으로 stale한 success snapshot — snapshot cache가 backoff 동작을 가리지 않도록
        let okSnapshot = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName,
            lines: [.progress(label: "Weekly quota", used: 12, limit: 100, format: .percent)],
            refreshedAt: Date(timeIntervalSince1970: 0)
        )
        let runtime = SequenceProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshots: [.error(provider: provider, message: "Not logged in"), okSnapshot]
        )
        let store = makeStore(provider: provider, descriptor: descriptor, runtime: runtime, clock: { clock })

        await store.refreshAll()                       // pass 1: 실패 → +60s까지 backoff
        XCTAssertEqual(runtime.refreshCount, 1)

        clock = clock.addingTimeInterval(1)
        await store.refreshAll(force: true)            // pass 2: window 내 forced success → backoff 해제
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertNil(store.errorMessage(for: provider.id))

        // pass 3은 원래 60s window 내 — probe 성공이 recovery 시 backoff 해제를 증명
        clock = clock.addingTimeInterval(1)
        await store.refreshAll()
        XCTAssertEqual(runtime.refreshCount, 3)
    }

    func testClearingBackoffAllowsImmediateReprobe() async {
        // re-enable 경로 — backoff 해제 직후 바로 probe 가능해야 5분 heartbeat까지 stale data에 갇히지 않음
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = makeFailingRuntime()
        let store = makeStore(runtime: runtime, clock: { clock })

        await store.refreshAll()                       // 실패 → backoff
        XCTAssertEqual(runtime.refreshCount, 1)

        clock = clock.addingTimeInterval(5)
        await store.refreshAll()                       // window 내 → 억제
        XCTAssertEqual(runtime.refreshCount, 1)

        store.clearFailureBackoff(for: runtime.provider.id)
        await store.refreshAll()                       // backoff 해제 → 즉시 probe
        XCTAssertEqual(runtime.refreshCount, 2)
    }

    // MARK: - Helpers

    private func makeFailingRuntime() -> CountingProviderRuntime {
        let provider = Provider(id: "devin", displayName: "Devin", icon: .providerMark("devin"))
        let descriptor = WidgetDescriptor(
            id: "devin.weekly", providerID: provider.id, metricLabel: "Weekly quota",
            sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: .error(provider: provider, message: "Not logged in")
        )
    }

    private func makeStore(
        runtime: some ProviderRuntime,
        clock: @escaping () -> Date
    ) -> WidgetDataStore {
        makeStore(provider: runtime.provider, descriptor: runtime.widgetDescriptors[0], runtime: runtime, clock: clock)
    }

    private func makeStore(
        provider: Provider,
        descriptor: WidgetDescriptor,
        runtime: some ProviderRuntime,
        clock: @escaping () -> Date
    ) -> WidgetDataStore {
        let suite = makeUserDefaults("backoff")
        return WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: suite, storageKey: "snapshots", ttl: 600, now: clock),
            defaults: suite,
            now: clock
        )
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Backoff.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

/// 호출마다 다른 snapshot 반환(마지막 반복) — 실패 후 회복하는 provider 모델링용
@MainActor
final class SequenceProviderRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    private let snapshots: [ProviderSnapshot]
    private(set) var refreshCount = 0

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshots: [ProviderSnapshot]) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshots = snapshots
    }

    func refresh() async -> ProviderSnapshot {
        let snapshot = snapshots[min(refreshCount, snapshots.count - 1)]
        refreshCount += 1
        return snapshot
    }
}
