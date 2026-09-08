import Observation
import os
import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitWidgetDataStoreTests: XCTestCase {
    func testDataUsesCurrentEnabledWindowWithoutAnotherRefresh() async {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("codex"))
        let session = WidgetDescriptor
            .percent(id: "fixture.session", provider: provider, title: "Session")
            .supportingSoftLimit(.fiveHours)
        let weekly = WidgetDescriptor
            .percent(id: "fixture.weekly", provider: provider, title: "Weekly")
            .supportingSoftLimit(.weekly)
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .progress(
                    label: "Session", used: 40, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.sessionMs
                ),
                .progress(
                    label: "Weekly", used: 50, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.weekMs
                )
            ]
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [session, weekly],
            snapshot: snapshot
        )
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        settings.thresholdPercent = 93
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [session, weekly]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            softLimitSettings: { settings }
        )

        await store.refreshAll(force: true)
        XCTAssertNil(store.data(for: session).softLimitUsedFraction)
        XCTAssertEqual(store.data(for: weekly).softLimitUsedFraction ?? -1, 0.93, accuracy: 0.0001)

        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.data(for: weekly).softLimitUsedFraction
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        settings.thresholdPercent = 92
        XCTAssertTrue(invalidated.withLock { $0 })
        XCTAssertEqual(store.data(for: weekly).softLimitUsedFraction ?? -1, 0.92, accuracy: 0.0001)

        settings.window = .fiveHours
        settings.thresholdPercent = 90
        XCTAssertEqual(store.data(for: session).softLimitUsedFraction ?? -1, 0.90, accuracy: 0.0001)
        XCTAssertNil(store.data(for: weekly).softLimitUsedFraction)
    }

    func testDataRequiresResolvedWindowDurationToMatchDescriptorOptIn() async {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("codex"))
        let exact = WidgetDescriptor
            .percent(id: "fixture.exact", provider: provider, title: "Exact")
            .supportingSoftLimit(.fiveHours)
        let dynamic = WidgetDescriptor
            .percent(id: "fixture.dynamic", provider: provider, title: "Dynamic")
            .supportingSoftLimit(.fiveHours)
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .progress(
                    label: "Exact", used: 40, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.sessionMs
                ),
                .progress(
                    label: "Dynamic", used: 50, limit: 100, format: .percent,
                    periodDurationMs: 3 * 60 * 60 * 1000
                )
            ]
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [exact, dynamic],
            snapshot: snapshot
        )
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        settings.window = .fiveHours
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [exact, dynamic]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            softLimitSettings: { settings }
        )

        await store.refreshAll(force: true)

        XCTAssertEqual(store.data(for: exact).softLimitUsedFraction ?? -1, 0.95, accuracy: 0.0001)
        XCTAssertNil(store.data(for: dynamic).softLimitUsedFraction)
    }

    func testSoftLimitAndResetWatchKeepIndependentMarkersAndPresentation() throws {
        let provider = CodexProvider()
        let descriptors = provider.widgetDescriptors
        let weekly = try XCTUnwrap(descriptors.first { $0.id == "codex.weekly" })
        let forecast = try XCTUnwrap(descriptors.first { $0.id == "codex.resetWatch" })
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(300)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: descriptors),
            providers: [], defaults: defaults, now: { now }, softLimitSettings: { settings }
        )
        store.snapshots["codex"] = ProviderSnapshot(
            providerID: "codex", displayName: "Codex",
            lines: [.progress(label: weekly.metricLabel, used: 95, limit: 100, format: .percent,
                              periodDurationMs: MetricPeriod.weekMs)]
        )
        store.setCodexResetWatch(CodexResetWatch(
            chancePercent: 75, deadline: deadline, communityYesPercent: 79
        ))

        for mode in [WidgetDisplayMode.used, .remaining] {
            store.meterStyle = mode
            let quota = store.data(for: weekly)
            let watch = store.data(for: forecast)
            XCTAssertEqual(quota.softLimitMarkerFraction ?? -1, mode == .used ? 0.95 : 0.05, accuracy: 0.0001)
            XCTAssertEqual(quota.softLimitStatusText, "Soft limit reached at 95% used")
            XCTAssertNil(quota.communityVoteTick)
            XCTAssertNil(watch.softLimitUsedFraction)
            XCTAssertNil(watch.softLimitMarkerFraction)
            XCTAssertNil(watch.softLimitStatusText)
            XCTAssertEqual(watch.fraction, 0.75)
            XCTAssertEqual(watch.communityVoteTick, 0.79)
            XCTAssertEqual(watch.communityVoteLabel, "79% expect a reset")
            XCTAssertFalse(watch.hasMeterStyleToggle)
            XCTAssertFalse(watch.presented(at: deadline).hasData)
            XCTAssertNil(watch.presented(at: deadline).communityVoteTick)
            XCTAssertTrue(quota.presented(at: deadline).hasData)
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.SoftLimit.WidgetDataStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
