import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreNotificationTests: XCTestCase {
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    /// `base` 시점에 주간 window의 약 90% 경과 — `used%` ≈ 예상 종료 %
    private var resetsAt: Date { base.addingTimeInterval(week * 0.10) }

    /// 게시된 notification 기록 sink — 항목은 `(idPrefix, title, subtitle, body)`
    private final class Recorder {
        var posts: [(String, String, String, String)] = []
    }

    /// store가 closure로 읽는 가변 enablement flag — captured var 경고 회피
    private final class EnabledFlag {
        var value: Bool
        init(_ value: Bool) { self.value = value }
    }

    private final class MutableRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var snapshot: ProviderSnapshot
        init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
            self.provider = provider
            self.widgetDescriptors = descriptors
            self.snapshot = snapshot
        }
        func refresh() async -> ProviderSnapshot { snapshot }
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suite = "WidgetDataStoreNotificationTests.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("cursor"))

    private static func descriptor() -> WidgetDescriptor {
        WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 10, limit: 100)
        )
    }

    private func snapshot(used: Double, resetsAt: Date? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: Self.provider.id,
            displayName: Self.provider.displayName,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent,
                              resetsAt: resetsAt ?? self.resetsAt, periodDurationMs: Int(week * 1000))]
        )
    }

    private func makeStore(
        used: Double,
        settings: NotificationSettingsStore,
        recorder: Recorder,
        defaultsName: String,
        isEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        delivered: @escaping @MainActor () -> Bool = { true }
    ) -> (WidgetDataStore, MutableRuntime, WidgetDescriptor) {
        let descriptor = Self.descriptor()
        let runtime = MutableRuntime(provider: Self.provider, descriptors: [descriptor], snapshot: snapshot(used: used))
        let defaults = makeUserDefaults(defaultsName)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [Self.provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults,
            isProviderEnabled: isEnabled,
            orderedDescriptors: { [descriptor] },
            notificationSettings: { settings },
            postNotification: { idPrefix, title, subtitle, body in
                recorder.posts.append((idPrefix, title, subtitle, body))
                return delivered()
            }
        )
        return (store, runtime, descriptor)
    }

    /// 세 trigger 전부 on — store 기본값이 off라 테스트에서 명시 opt-in
    private func allOn(_ settings: NotificationSettingsStore) {
        settings.underTenPercent = true
        settings.healthyToClose = true
        settings.closeToRunningOut = true
    }

    func testHealthyToCloseFiresOnceThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("h2c-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "h2c")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty, "healthy should not fire")

        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 1)
        XCTAssertEqual(recorder.posts.first?.0, "test.healthyToClose")
        XCTAssertEqual(recorder.posts.first?.1, "Cutting It Close")

        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 1)
    }

    func testCloseToRunningOutFiresThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("c2r-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 87, settings: settings, recorder: recorder, defaultsName: "c2r")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty, "first launch primes the baseline without firing")

        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
        XCTAssertTrue(recorder.posts.contains { $0.3 == "Projected to finish before the limit resets." })
        XCTAssertTrue(recorder.posts.contains { $0.2 == "Test Session" })
    }

    func testResetJitterDoesNotRefireRunningOutThroughTheStore() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("jitter-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "jitter")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)

        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.filter { $0.0 == "test.closeToRunningOut" }.count, 1)

        runtime.snapshot = snapshot(used: 95, resetsAt: resetsAt.addingTimeInterval(0.09))
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)

        XCTAssertEqual(recorder.posts.filter { $0.0 == "test.closeToRunningOut" }.count, 1)
    }

    func testAllTogglesOffSuppressesAllPosts() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("all-off-settings"))
        settings.underTenPercent = false
        settings.healthyToClose = false
        settings.closeToRunningOut = false
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "all-off")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.isEmpty)
    }

    func testPerTriggerOffSuppressesThatMilestoneOnly() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("per-trigger-settings"))
        allOn(settings)
        settings.healthyToClose = false
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "per-trigger")
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertFalse(recorder.posts.contains { $0.0 == "test.healthyToClose" })
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(recorder.posts.contains { $0.0 == "test.closeToRunningOut" })
    }

    func testDisablingProviderDropsItsNotificationState() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("disable-settings"))
        allOn(settings)
        let recorder = Recorder()
        let enabled = EnabledFlag(true)
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder,
                                            defaultsName: "disable", isEnabled: { _ in enabled.value })
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 0)
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        let firstCount = recorder.posts.count
        XCTAssertGreaterThan(firstCount, 0)

        enabled.value = false
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, firstCount)
    }

    func testLowRemainingFiresInUsedDisplayMode() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("used-mode-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder, defaultsName: "used-mode")
        store.meterStyle = .used
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 95)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertTrue(
            recorder.posts.contains { $0.0 == "test.underTenPercent" },
            "Almost Out must fire on <10% remaining even when the meter displays 'used'"
        )
    }

    func testFailedDeliveryRetriesNextTick() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("retry-settings"))
        allOn(settings)
        let recorder = Recorder()
        let (store, runtime, _) = makeStore(used: 80, settings: settings, recorder: recorder,
                                            defaultsName: "retry", delivered: { false })
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        runtime.snapshot = snapshot(used: 87)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: base)
        XCTAssertEqual(recorder.posts.count, 2, "failed delivery should retry on the next tick")
    }

    func testResetWatchNeverEntersQuotaNotifications() async {
        let settings = NotificationSettingsStore(defaults: makeUserDefaults("forecast-settings"))
        allOn(settings)
        let recorder = Recorder()
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.forecast(
            id: "codex.resetWatch",
            provider: provider,
            title: "Reset Watch"
        )
        let deadline = base.addingTimeInterval(3600)
        let runtime = MutableRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: []
            )
        )
        let defaults = makeUserDefaults("forecast")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults,
            orderedDescriptors: { [descriptor] },
            now: { self.base },
            notificationSettings: { settings },
            postNotification: { idPrefix, title, subtitle, body in
                recorder.posts.append((idPrefix, title, subtitle, body))
                return true
            }
        )

        store.setCodexResetWatch(CodexResetWatch(chancePercent: 80, deadline: deadline))
        await store.evaluateNotifications(now: base)
        store.setCodexResetWatch(CodexResetWatch(chancePercent: 100, deadline: deadline))
        await store.evaluateNotifications(now: base)

        XCTAssertTrue(recorder.posts.isEmpty)
    }
}
