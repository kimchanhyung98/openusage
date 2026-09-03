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

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.SoftLimit.WidgetDataStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
