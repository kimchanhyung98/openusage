import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreTests: XCTestCase {
    func testResolvesProgressSnapshotIntoWidgetData() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(
                    label: "Session",
                    used: 42,
                    limit: 100,
                    format: .percent,
                    resetsAt: Date(timeIntervalSinceNow: 60 * 60),
                    periodDurationMs: 5 * 60 * 60 * 1000
                )]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        // isolated suite로 meterStyle 고정 — persisted `.used` 간섭 차단
        let store = WidgetDataStore(registry: registry, providers: [runtime], defaults: makeUserDefaults("resolve-progress"))
        store.meterStyle = .remaining

        await store.refreshAll()
        let data = store.data(for: descriptor)

        XCTAssertEqual(data.used, 42)
        XCTAssertEqual(data.displayedValue, 58)
        XCTAssertEqual(data.valueText, "58%")
        XCTAssertEqual(data.boundedHeadline, "58% left")
        XCTAssertEqual(data.boundedSubtitle?.hasPrefix("Resets in "), true)
    }

    func testSoftWarningSurfacesOnHeaderWhilePartialDataStillLoads() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let meter = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [meter],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                warning: "Re-login for live usage. Run `claude` and sign in again."
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("soft-warning")
        )

        await store.refreshAll()

        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage. Run `claude` and sign in again.")
        XCTAssertNil(store.errorMessage(for: provider.id))
        XCTAssertTrue(store.data(for: meter).hasData)
    }

    func testHardErrorTakesPrecedenceOverStaleSoftWarning() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("claude"))
        let meter = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TogglingProviderRuntime(
            provider: provider,
            descriptors: [meter],
            first: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                warning: "Re-login for live usage."
            ),
            second: ProviderSnapshot.error(provider: provider, message: "Token expired. Run `claude` to log in again.")
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [meter]),
            providers: [runtime],
            defaults: makeUserDefaults("header-notice")
        )

        await store.refreshAll(force: true)
        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage.")
        XCTAssertEqual(store.headerNotice(for: provider.id), "Re-login for live usage.")

        await store.refreshAll(force: true)
        XCTAssertEqual(store.errorMessage(for: provider.id), "Token expired. Run `claude` to log in again.")
        XCTAssertEqual(store.warningMessage(for: provider.id), "Re-login for live usage.")
        XCTAssertEqual(store.headerNotice(for: provider.id), "Token expired. Run `claude` to log in again.")
    }

    func testRemainingProgressWithoutResetUsesPeriodDurationLabel() {
        let session = WidgetData(
            title: "Session",
            icon: .providerMark("claude"),
            kind: .percent,
            used: 0,
            limit: 100,
            displayMode: .remaining,
            resetsAt: nil,
            periodDurationMs: ClaudeUsageMapper.sessionPeriodMs
        )
        XCTAssertEqual(session.boundedSubtitle, "Resets in 5h")

        let weekly = WidgetData(
            title: "Weekly",
            icon: .providerMark("claude"),
            kind: .percent,
            used: 0,
            limit: 100,
            displayMode: .remaining,
            resetsAt: nil,
            periodDurationMs: ClaudeUsageMapper.weeklyPeriodMs
        )
        XCTAssertEqual(weekly.boundedSubtitle, "Resets in 7d 0h")
    }

    func testDollarLimitSubtitleIsNotAReset() {
        let onDemand = WidgetData(
            title: "On-demand", icon: .providerMark("cursor"),
            kind: .dollars, used: 0, limit: 100, limitNoun: "limit"
        )
        XCTAssertEqual(onDemand.boundedSubtitle, "$100 limit")
    }

    func testDonutFractionMatchesRoundedHeadline() {
        let nearlyZero = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 0.3915,
            limit: 100
        )
        XCTAssertEqual(nearlyZero.valueText, "0%")
        XCTAssertEqual(nearlyZero.fraction, 0, accuracy: 0.0001)

        let roundsUp = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 0.6,
            limit: 100
        )
        XCTAssertEqual(roundsUp.valueText, "1%")
        XCTAssertEqual(roundsUp.fraction, 0.01, accuracy: 0.0001)

        let nearlyFull = WidgetData(
            title: "Total usage",
            icon: .providerMark("cursor"),
            kind: .percent,
            used: 99.6,
            limit: 100
        )
        XCTAssertEqual(nearlyFull.valueText, "100%")
        XCTAssertEqual(nearlyFull.fraction, 1, accuracy: 0.0001)
    }

    func testOnDemandDollarLimitAppendsLimitNoun() {
        let onDemand = WidgetData(
            title: "On-Demand",
            icon: .providerMark("cursor"),
            kind: .dollars,
            used: 0,
            limit: 100,
            limitNoun: "limit"
        )
        XCTAssertEqual(onDemand.boundedSubtitle, "$100 limit")
    }

    func testCreditsDollarLimitAppendsLimitNoun() {
        let credits = WidgetData(
            title: "Credits",
            icon: .providerMark("cursor"),
            kind: .dollars,
            used: 0,
            limit: 20,
            limitNoun: "limit"
        )
        XCTAssertEqual(credits.boundedSubtitle, "$20 limit")
    }

    func testRequestsShowsBillingResetInsteadOfSuffix() {
        let requests = WidgetData(
            title: "Requests",
            icon: .providerMark("cursor"),
            kind: .count,
            used: 0,
            limit: 500,
            countSuffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        XCTAssertEqual(requests.boundedSubtitle, "Resets in 30d 0h")
    }

    func testCreditsRenderDollarAndCountCombinedInvariantToMeterStyle() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.combined(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: CodexUsageMapper.creditValues(remaining: 1000))]
            )
        )
        let defaults = makeUserDefaults("codex-credits")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$40.00 · 1K credits")
        XCTAssertEqual(remaining.menuBarValue, "$40")
        XCTAssertNil(remaining.unboundedSubtitle)

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.headline, remaining.headline)
    }

    func testRateLimitResetsTileShowsCountInTrayAndPopover() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 1, kind: .count, label: "available")])]
            )
        )
        let defaults = makeUserDefaults("codex-resets")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "1 available")
        XCTAssertEqual(data.menuBarValue, "1 resets")
    }

    func testZeroRateLimitResetsStillFlagsResetPopoverForEmptyState() async {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets",
            provider: provider,
            title: "Rate Limit Resets",
            metricLabel: "Rate Limit Resets",
            traySuffix: "resets",
            showsResetExpiries: true
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Rate Limit Resets",
                                values: [MetricValue(number: 0, kind: .count, label: "available")])]
            )
        )
        let defaults = makeUserDefaults("codex-resets-empty")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.showsResetExpiries)
        XCTAssertTrue(data.hasData)
        XCTAssertTrue(data.expiriesAt.isEmpty)
        XCTAssertNil(data.expirySeverity())
        XCTAssertEqual(data.unboundedDetail, "0 available")
    }

    func testBoundedDollarAndCountTrayValuesHonorMeterStyleWithoutPercentConversion() async {
        let provider = Provider(id: "example", displayName: "Example", icon: .providerMark("cursor"))
        let budget = WidgetDescriptor.boundedDollars(id: "example.budget", provider: provider, title: "Budget", limit: 100)
        let requests = WidgetDescriptor.boundedCount(
            id: "example.requests",
            provider: provider,
            title: "Requests",
            limit: 500,
            suffix: "requests",
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [budget, requests],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .progress(label: "Budget", used: 12.48, limit: 20, format: .dollars),
                    .progress(label: "Requests", used: 412, limit: 500, format: .count(suffix: "requests"))
                ]
            )
        )
        let defaults = makeUserDefaults("cursor-tray-units")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [budget, requests]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .used
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$12")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "412")

        store.meterStyle = .remaining
        XCTAssertEqual(store.data(for: budget).menuBarValue, "$8")
        XCTAssertEqual(store.data(for: requests).menuBarValue, "88")
    }

    func testCursorCreditsRenderAsUnboundedBalance() async {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let descriptor = WidgetDescriptor.dollarBalance(
            id: "cursor.credits",
            provider: provider,
            title: "Credits",
            valueWord: "left"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Credits", values: [MetricValue(number: 7_909.64, kind: .dollars)])]
            )
        )
        let defaults = makeUserDefaults("cursor-credits-balance")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        store.meterStyle = .remaining
        let remaining = store.data(for: descriptor)
        XCTAssertFalse(remaining.isBounded)
        XCTAssertEqual(remaining.unboundedDetail, "$7.9K left")
        XCTAssertEqual(remaining.menuBarValue, "$7.9K")

        store.meterStyle = .used
        let used = store.data(for: descriptor)
        XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
        XCTAssertEqual(used.menuBarValue, remaining.menuBarValue)
    }

    func testUncappedExtraUsageRendersCompactAndUnbounded() async {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.boundedDollars(
            id: "claude.extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100, valueWord: "spent"
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.values(label: "Extra usage spent",
                                values: [MetricValue(number: 1234.56, kind: .dollars)])]
            )
        )
        let defaults = makeUserDefaults("claude-extra")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() }),
            defaults: defaults
        )
        await store.refreshAll()

        let data = store.data(for: descriptor)
        XCTAssertTrue(data.hasData)
        XCTAssertFalse(data.isBounded)
        XCTAssertEqual(data.unboundedDetail, "$1.2K spent")
        XCTAssertEqual(data.menuBarValue, "$1.2K")
        XCTAssertEqual(data.unboundedTooltip, "$1,234.56")
    }

    func testCreditValuesFloorAndClampBalance() {
        var data = WidgetData(title: "Extra Usage", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.values = CodexUsageMapper.creditValues(remaining: 820.9)
        XCTAssertEqual(data.unboundedDetail, "$32.80 · 820 credits")
        data.values = CodexUsageMapper.creditValues(remaining: -5)
        XCTAssertEqual(data.unboundedDetail, "$0.00 · 0 credits")
    }

    func testCreditsRenderUpToOneDecimalPlace() {
        let credits = WidgetData(
            title: "Extra Usage",
            icon: .providerMark("codex"),
            kind: .count,
            used: 820.55,
            limit: nil,
            countSuffix: "credits",
            unboundedValueWord: "left"
        )

        XCTAssertEqual(credits.valueText, "820.6")
        XCTAssertEqual(credits.unboundedDetail, "820.6 credits left")
    }

    func testCcusageSpendSplitsIntoCostTokensAndCombined() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let cost = WidgetDescriptor.values(id: "test.last30", provider: provider, title: "Last 30 Days",
                                           selection: .kind(.dollars), valueWord: "spent")
        let tokens = WidgetDescriptor.values(id: "test.last30.tokens", provider: provider,
                                             title: "Tokens", metricLabel: "Last 30 Days", selection: .kind(.count))
        let combined = WidgetDescriptor.combined(id: "test.last30.combined", provider: provider,
                                                 title: "Combined", metricLabel: "Last 30 Days")
        let todayCost = WidgetDescriptor.values(id: "test.today", provider: provider, title: "Today",
                                                selection: .kind(.dollars), valueWord: "spent")
        let descriptors = [cost, tokens, combined, todayCost]
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: descriptors,
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .values(label: "Last 30 Days", values: [
                        MetricValue(number: 478.0, kind: .dollars, estimated: true),
                        MetricValue(number: 891_000, kind: .count, label: "tokens")
                    ]),
                    // 미가격 산정일: tokens만 존재, dollar 없음 (cost는 unknown이지 0 아님)
                    .values(label: "Today", values: [MetricValue(number: 123_000, kind: .count, label: "tokens")])
                ]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("local-estimate"),
            storageKey: "snapshots",
            ttl: 600,
            now: { Date() }
        )
        let store = WidgetDataStore(registry: registry, providers: [runtime], cache: cache)
        await store.refreshAll()

        let costData = store.data(for: cost)
        XCTAssertEqual(costData.valueText, "$478.00")
        XCTAssertEqual(costData.unboundedDetail, "$478.00 spent")
        XCTAssertEqual(costData.infoNote, WidgetData.localEstimateNote)

        let tokenData = store.data(for: tokens)
        XCTAssertEqual(tokenData.unboundedDetail, "891K tokens")
        XCTAssertEqual(tokenData.menuBarValue, "891K tokens")
        XCTAssertEqual(tokenData.unboundedTooltip, "891,000 tokens")
        XCTAssertNil(tokenData.infoNote)

        let combinedData = store.data(for: combined)
        XCTAssertEqual(combinedData.unboundedDetail, "$478.00 · 891K tokens")
        XCTAssertEqual(combinedData.menuBarValue, "$478")
        XCTAssertEqual(combinedData.unboundedTooltip, "$478.00 · 891,000 tokens")
        XCTAssertEqual(combinedData.infoNote, WidgetData.localEstimateNote)

        XCTAssertEqual(combinedData.unboundedValueTooltip, "$478.00 · 891,000 tokens\n\(WidgetData.localEstimateNote)")
        XCTAssertEqual(costData.unboundedValueTooltip, "$478.00\n\(WidgetData.localEstimateNote)")
        XCTAssertNil(tokenData.infoNote)
        XCTAssertEqual(tokenData.unboundedValueTooltip, "891,000 tokens")

        let todayData = store.data(for: todayCost)
        XCTAssertFalse(todayData.hasData)
        XCTAssertEqual(todayData.valueText, WidgetData.noDataHeadline)
    }

    func testCursorSpendValueTooltipUsesUsageHistorySourceNote() async {
        let cursor = CursorProvider()
        let provider = cursor.provider
        let combined = cursor.widgetDescriptors.first { $0.id == "cursor.last30" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [combined],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [
                    .values(label: "Last 30 Days", values: [
                        MetricValue(number: 15.80, kind: .dollars),
                        MetricValue(number: 8_100_000_000, kind: .count, label: "tokens")
                    ])
                ]
            )
        )
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: [combined]), providers: [runtime])
        await store.refreshAll()

        let data = store.data(for: combined)
        XCTAssertEqual(data.unboundedDetail, "$15.80 · 8.1B tokens")
        XCTAssertNil(data.infoNote)
        XCTAssertEqual(data.unboundedValueTooltip, "$15.80 · 8,100,000,000 tokens\n\(WidgetData.cursorUsageHistoryNote)")
    }

    func testUsesFreshCachedSnapshotInsteadOfRefreshingProvider() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = ProviderSnapshotCache(
            userDefaults: makeUserDefaults("fresh-cache"),
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-60)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("fresh-cache-meter")
        )
        store.meterStyle = .remaining

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 0)
        XCTAssertEqual(store.data(for: descriptor).valueText, "80%")
    }

    func testExpiredCacheRefreshesAndReplacesSnapshot() async {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "test.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100, displayMode: .remaining)
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let defaults = makeUserDefaults("expired-cache")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults,
            storageKey: "snapshots",
            ttl: 600,
            now: { now }
        )
        cache.store(ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [.progress(label: "Session", used: 20, limit: 100, format: .percent)],
            refreshedAt: now.addingTimeInterval(-601)
        ))
        let runtime = CountingProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 80, limit: 100, format: .percent)],
                refreshedAt: now
            )
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            cache: cache,
            defaults: makeUserDefaults("expired-cache-meter")
        )
        store.meterStyle = .remaining

        await store.refreshAll()

        XCTAssertEqual(runtime.refreshCount, 1)
        XCTAssertEqual(store.data(for: descriptor).valueText, "20%")
    }

    func testDataForStampsTheProviderIDOnBothBranches() async {
        let provider = Provider(id: "codex@ab12cd34", displayName: "Codex — Work", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor(
            id: "codex@ab12cd34.session",
            providerID: provider.id,
            metricLabel: "Session",
            sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100)
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)]
            )
        )
        let registry = WidgetRegistry(providers: [provider], descriptors: [descriptor])
        let store = WidgetDataStore(registry: registry, providers: [runtime], defaults: makeUserDefaults("provider-id-stamp"))

        XCTAssertEqual(store.data(for: descriptor).providerID, provider.id)

        await store.refreshAll()
        XCTAssertEqual(store.data(for: descriptor).providerID, provider.id)
    }

    private func makeUserDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
