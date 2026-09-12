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

        XCTAssertEqual(store.data(for: exact).softLimitUsedFraction ?? -1, 0.90, accuracy: 0.0001)
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
        settings.thresholdPercent = 95
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
            XCTAssertTrue(watch.presented(at: deadline).hasData)
            XCTAssertEqual(watch.presented(at: deadline).boundedHeadline, "0% chance")
            XCTAssertNil(watch.presented(at: deadline).communityVoteTick)
            XCTAssertTrue(quota.presented(at: deadline).hasData)
        }
    }

    func testAccountCardsKeepIndependentUsageAndShareOnlyTheGuideAndForecast() throws {
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        settings.thresholdPercent = 95
        let cards = [
            AccountUsageSnapshotCard(id: "claude@profile-review", profileID: "review-claude", family: "claude"),
            AccountUsageSnapshotCard(id: "codex@profile-review", profileID: "review-codex", family: "codex")
        ]
        let runtimes = ProviderCatalog.make(defaults: defaults, snapshotCards: cards)
        let registry = WidgetRegistry.from(runtimes)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = WidgetDataStore(
            registry: registry, providers: [], defaults: defaults, now: { now },
            softLimitSettings: { settings }
        )
        let usage = ["claude": 40.0, cards[0].id: 95.0, "codex": 70.0, cards[1].id: 98.0]
        for (id, used) in usage {
            store.snapshots[id] = ProviderSnapshot(
                providerID: id, displayName: id,
                lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent,
                                  periodDurationMs: MetricPeriod.weekMs)]
            )
        }
        store.setCodexResetWatch(CodexResetWatch(
            chancePercent: 45, deadline: now.addingTimeInterval(300), communityYesPercent: 79
        ))

        for (id, used) in usage {
            let descriptor = try XCTUnwrap(registry.descriptor(id: "\(id).weekly"))
            XCTAssertEqual(descriptor.softLimitWindow, .weekly)
            let data = store.data(for: descriptor)
            XCTAssertEqual(data.providerID, id)
            XCTAssertEqual(data.used, used)
            XCTAssertEqual(data.softLimitUsedFraction, 0.95)
            XCTAssertEqual(data.softLimitStatusText, used >= 95
                ? "Soft limit reached at 95% used" : "Soft limit at 95% used")
        }
        for id in ["codex", cards[1].id] {
            let watch = store.data(for: try XCTUnwrap(registry.descriptor(id: "\(id).resetWatch")))
            XCTAssertEqual(watch.providerID, id)
            XCTAssertEqual(watch.used, 45)
            XCTAssertEqual(watch.communityVoteTick, 0.79)
            XCTAssertNil(watch.softLimitMarkerFraction)
        }
        settings.enabled = false
        for (id, used) in usage {
            let data = store.data(for: try XCTUnwrap(registry.descriptor(id: "\(id).weekly")))
            XCTAssertEqual(data.used, used)
            XCTAssertNil(data.softLimitMarkerFraction)
        }
    }

    func testGuideChangesLeaveQuotaStateNotificationsAndLimitsAPIUnchanged() async throws {
        let provider = CodexProvider()
        let registry = WidgetRegistry.from([provider])
        let weekly = try XCTUnwrap(registry.descriptor(id: "codex.weekly"))
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults)
        let notifications = NotificationSettingsStore(defaults: defaults)
        notifications.underTenPercent = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var posts: [String] = []
        let store = WidgetDataStore(
            registry: registry, providers: [], defaults: defaults, now: { now },
            notificationSettings: { notifications }, softLimitSettings: { settings },
            postNotification: { id, _, _, _, isCurrent in
                guard isCurrent() else { return false }
                posts.append(id)
                return true
            }
        )
        func setUsage(_ used: Double) {
            store.snapshots["codex"] = ProviderSnapshot(
                providerID: "codex", displayName: "Codex",
                lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent,
                                  resetsAt: now.addingTimeInterval(600), periodDurationMs: MetricPeriod.weekMs)],
                refreshedAt: now
            )
        }
        func limits() -> Data {
            LocalLimitsAPI.encode(providerIDs: ["codex"], state: .init(
                enabledOrderedIDs: ["codex"], knownIDs: ["codex"], snapshots: store.snapshots,
                limitDescriptors: store.limitDescriptorsByProvider, generatedAt: now
            ))
        }
        setUsage(89)
        await store.evaluateNotifications(now: now)
        let baseline = store.data(for: weekly)
        let baselineLimits = limits()

        for threshold in SoftLimitSettingsStore.thresholdRange {
            settings.enabled = true
            settings.thresholdPercent = threshold
            for mode in [WidgetDisplayMode.used, .remaining] {
                store.meterStyle = mode
                let data = store.data(for: weekly)
                XCTAssertNotNil(data.softLimitMarkerFraction)
                XCTAssertEqual(data.used, baseline.used)
                XCTAssertEqual(data.limit, baseline.limit)
                XCTAssertEqual(data.resetsAt, baseline.resetsAt)
                XCTAssertEqual(data.remainingFraction, baseline.remainingFraction)
                XCTAssertEqual(data.meterState(now: now), baseline.meterState(now: now))
                XCTAssertEqual(limits(), baselineLimits)
                await store.evaluateNotifications(now: now)
                XCTAssertTrue(posts.isEmpty)
            }
        }

        setUsage(91)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["codex.underTenPercent"])
        settings.enabled = false
        await store.evaluateNotifications(now: now)
        settings.enabled = true
        settings.window = .fiveHours
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["codex.underTenPercent"])
        XCTAssertNil(store.data(for: weekly).softLimitMarkerFraction)
    }

    func testPresentedAccountModesKeepGuidesSeparateFromSharedHomeResetWatch() throws {
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults)
        settings.enabled = true
        let cardIDs = ["claude", "claude@profile-work", "codex", "codex@profile-work"]
        let providers = cardIDs.map { id in
            ProviderAccountID.family(of: id) == "claude"
                ? ClaudeProvider.makeProvider(id: id) : CodexProvider.makeProvider(id: id)
        }
        let descriptors = providers.flatMap { provider in
            ProviderAccountID.family(of: provider.id) == "claude"
                ? ClaudeProvider(provider: provider).widgetDescriptors
                : CodexProvider(provider: provider).widgetDescriptors
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let metricIDs = ["claude.weekly", "codex.weekly", "codex.resetWatch"]
        let layout = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: metricIDs, migrationBaselineMetricIDs: metricIDs,
            defaultPinnedMetricIDs: ["codex.weekly"], defaultExpandedMetricIDs: ["codex.resetWatch"]
        )
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults, softLimitSettings: { settings })
        let usage = ["claude": 30.0, "claude@profile-work": 40, "codex": 90, "codex@profile-work": 95]
        for (id, used) in usage {
            store.snapshots[id] = .init(providerID: id, displayName: id, lines: [
                .progress(label: "Weekly", used: used, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
            ])
        }
        store.setCodexResetWatch(.init(chancePercent: 75, deadline: .distantFuture, communityYesPercent: 60))
        let originalPlaced = layout.placed
        let originalExpanded = layout.expandedMetricIDs
        let originalPins = layout.pinnedMetricIDs

        for mode in [AccountCardDisplayMode.singleCard, .separateCards] {
            let visibleIDs = AccountCardPresentationPlanner.presentedCardIDs(
                orderedCardIDs: cardIDs,
                modesByFamily: ["claude": mode, "codex": mode],
                selectedCardIDsByFamily: ["claude": cardIDs[1], "codex": cardIDs[3]]
            )
            XCTAssertEqual(visibleIDs, mode == .singleCard ? [cardIDs[1], cardIDs[3]] : cardIDs)
            for raw in layout.displayGroups where visibleIDs.contains(raw.id) {
                let group = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(raw, mode: mode))
                for display in [WidgetDisplayMode.used, .remaining] {
                    store.meterStyle = display
                    let rows = try group.widgets.map { store.data(for: try XCTUnwrap(layout.descriptor(for: $0))) }
                    let quota = try XCTUnwrap(rows.first { $0.title == "Weekly" })
                    XCTAssertEqual(quota.used, usage[group.id])
                    XCTAssertEqual(quota.softLimitMarkerFraction ?? -1, display == .used ? 0.90 : 0.10, accuracy: 0.0001)
                    let showsWatch = ProviderAccountID.family(of: group.id) == "codex"
                        && (mode == .singleCard || group.id == "codex")
                    XCTAssertEqual(rows.filter(\.isForecast).count, showsWatch ? 1 : 0)
                    XCTAssertTrue(rows.filter(\.isForecast).allSatisfy { $0.softLimitMarkerFraction == nil })
                }
            }
        }
        XCTAssertEqual(layout.placed, originalPlaced)
        XCTAssertEqual(layout.expandedMetricIDs, originalExpanded)
        XCTAssertEqual(layout.pinnedMetricIDs, originalPins)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.SoftLimit.WidgetDataStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
