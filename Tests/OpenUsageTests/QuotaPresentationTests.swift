import XCTest
@testable import OpenUsage

@MainActor
final class QuotaPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Runtime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var snapshot: ProviderSnapshot

        init(provider: Provider, descriptors: [WidgetDescriptor]) {
            self.provider = provider
            self.widgetDescriptors = descriptors
            self.snapshot = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        }

        func refresh() async -> ProviderSnapshot { snapshot }

        func setUsage(_ used: Double, reset: Date?, period: Int = MetricPeriod.sessionMs) {
            snapshot = ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [.progress(label: "Session", used: used, limit: 100, format: .percent,
                                  resetsAt: reset, periodDurationMs: period)]
            )
        }
    }

    private final class Recorder {
        var titles: [String] = []
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "QuotaPresentationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testClaudeSessionSignalSurvivesStoreResolutionAndSoftLimitSettings() async throws {
        for cardID in ["claude", "claude@profile-work"] {
            let provider = ClaudeProvider(provider: ClaudeProvider.makeProvider(id: cardID))
            let session = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "\(cardID).session" })
            let weekly = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "\(cardID).weekly" })
            let runtime = Runtime(provider: provider.provider, descriptors: provider.widgetDescriptors)
            let defaults = makeDefaults()
            let softLimit = SoftLimitSettingsStore(defaults: defaults)
            softLimit.enabled = true
            softLimit.window = .fiveHours
            softLimit.thresholdPercent = 90
            let store = WidgetDataStore(
                registry: WidgetRegistry.from([runtime]), providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults,
                softLimitSettings: { softLimit }, providerIdentityKeys: [cardID: "account"]
            )
            XCTAssertFalse(store.data(for: session).hasData)
            XCTAssertFalse(store.data(for: session).isFreshSessionWindow(now: now))
            XCTAssertEqual(session.softLimitWindow, .fiveHours)
            XCTAssertNil(weekly.sample.sessionStartSignal)

            for reset in [nil, now.addingTimeInterval(9_000)] {
                runtime.setUsage(0, reset: reset)
                await store.refresh(providerID: cardID, force: true)
                for mode in [WidgetDisplayMode.used, .remaining] {
                    store.meterStyle = mode
                    let data = store.data(for: session)
                    XCTAssertEqual(data.providerID, cardID)
                    XCTAssertEqual(data.used, 0)
                    XCTAssertEqual(data.sessionStartSignal, .missingResetDate)
                    XCTAssertEqual(data.isFreshSessionWindow(now: now), reset == nil)
                    XCTAssertEqual(data.hasResetLabel(now: now), reset != nil)
                    XCTAssertEqual(data.softLimitUsedFraction, 0.9)
                    XCTAssertEqual(data.softLimitMarkerFraction ?? -1, mode == .used ? 0.9 : 0.1, accuracy: 0.0001)
                    XCTAssertEqual(data.meterState(now: now), .level(.normal))
                    XCTAssertNil(data.paceTick(for: data.meterState(now: now), now: now))
                }
                XCTAssertEqual(store.accountStatus(for: cardID, localState: .ready(identityKey: "account", label: nil)), .ready)
            }

            let lastGood = store.localSnapshots[cardID]
            runtime.snapshot = .error(provider: runtime.provider, error: ClaudeUsageError.connectionFailed)
            await store.refresh(providerID: cardID, force: true)
            XCTAssertEqual(store.localSnapshots[cardID], lastGood)
            XCTAssertTrue(store.data(for: session).hasResetLabel(now: now))
            XCTAssertEqual(store.accountStatus(for: cardID, localState: .ready(identityKey: "account", label: nil)),
                           .refreshFailed(ClaudeUsageError.connectionFailed.localizedDescription))
        }
    }

    func testZeroUsageDoesNotRearmPaceNotificationsBeforeTheWindowAdvances() async {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.percent(id: "fixture.session", provider: provider, title: "Session")
            .supportingSoftLimit(.weekly)
        let runtime = Runtime(provider: provider, descriptors: [descriptor])
        let defaults = makeDefaults()
        let notifications = NotificationSettingsStore(defaults: defaults)
        notifications.healthyToClose = true
        notifications.closeToRunningOut = true
        let softLimit = SoftLimitSettingsStore(defaults: defaults)
        softLimit.enabled = true
        softLimit.window = .weekly
        let recorder = Recorder()
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults,
            notificationSettings: { notifications }, softLimitSettings: { softLimit },
            postNotification: { _, title, _, _, _ in recorder.titles.append(title); return true }
        )
        let reset = now.addingTimeInterval(Double(MetricPeriod.weekMs) / 2_000)
        for (used, expectedCount) in [(0.0, 0), (46.0, 1), (0.0, 1), (46.0, 1), (30.0, 1), (46.0, 2)] {
            runtime.setUsage(used, reset: reset, period: MetricPeriod.weekMs)
            await store.refresh(providerID: provider.id, force: true)
            await store.evaluateNotifications(now: now)
            XCTAssertEqual(store.data(for: descriptor).softLimitUsedFraction, 0.9)
            XCTAssertEqual(recorder.titles.count, expectedCount)
        }
        XCTAssertEqual(recorder.titles, ["Cutting It Close", "Cutting It Close"])

        runtime.setUsage(46, reset: reset.addingTimeInterval(2), period: MetricPeriod.weekMs)
        await store.refresh(providerID: provider.id, force: true)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(recorder.titles, ["Cutting It Close", "Cutting It Close", "Cutting It Close"])
    }
}
