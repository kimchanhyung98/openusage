import XCTest
@testable import OpenUsage

@MainActor
final class OpenRouterTotalSpendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEnabledOpenRouterContributesDedicatedTotalsEvenWhenAllCardMetricsAreHidden() {
        let runtime = OpenRouterProvider()
        let registry = WidgetRegistry.from([runtime])
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let enablement = ProviderEnablementStore(defaults: defaults)
        let layout = LayoutStore(
            registry: registry,
            defaults: defaults,
            storageKey: "layout",
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        for descriptor in registry.descriptors {
            layout.setMetricEnabled(descriptor.id, false)
        }
        let snapshot = snapshot(runtime.provider, totals: [line("Today", dollars: 2, tokens: 500_000)])

        XCTAssertTrue(runtime.provider.usesDedicatedSpendLines)
        XCTAssertFalse(registry.descriptors.contains(where: \.isSpendTile))
        XCTAssertNil(registry.historyDescriptorsByProvider["openrouter"])
        XCTAssertTrue(layout.displayGroups.isEmpty)
        XCTAssertTrue(layout.hasSpendCapableProvider)
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["openrouter"])
        let total = TotalSpendAggregator.total(
            for: .today, providers: layout.spendCapableProviders, snapshots: ["openrouter": snapshot]
        )
        XCTAssertEqual(total.totalUSD, 2)
        XCTAssertEqual(total.totalTokens, 500_000)
        XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, 4)

        enablement.setEnabled(false, for: "openrouter")

        XCTAssertFalse(layout.hasSpendCapableProvider)
        XCTAssertTrue(layout.spendCapableProviders.isEmpty)
        XCTAssertTrue(TotalSpendAggregator.total(
            for: .today, providers: layout.spendCapableProviders, snapshots: ["openrouter": snapshot]
        ).isEmpty)
    }

    func testDedicatedAndExistingProviderTotalsUseTheirOwnSources() {
        let openRouter = OpenRouterProvider()
        let claude = ClaudeProvider()
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = LayoutStore(
            registry: .from([claude, openRouter]), defaults: defaults, storageKey: "layout"
        )
        let snapshots = [
            "openrouter": snapshot(
                openRouter.provider,
                lines: [line("Today", dollars: 99, tokens: 9_000_000)],
                totals: [line("Today", dollars: 4, tokens: 500_000)]
            ),
            "claude": snapshot(
                claude.provider,
                lines: [line("Today", dollars: 6, tokens: 1_500_000, estimated: true)],
                totals: [line("Today", dollars: 88, tokens: 8_000_000)]
            )
        ]

        XCTAssertFalse(claude.provider.usesDedicatedSpendLines)
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["claude", "openrouter"])
        let total = TotalSpendAggregator.total(
            for: .today, providers: layout.spendCapableProviders, snapshots: snapshots
        )

        XCTAssertEqual(total.totalUSD, 10)
        XCTAssertEqual(total.totalTokens, 2_000_000)
        XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, 5)
        XCTAssertTrue(total.isEstimated)
        XCTAssertFalse(total.slices.first { $0.id == "openrouter" }?.estimated ?? true)
    }

    func testOrdinaryKeyRowsAreExcludedWhenDedicatedTotalsAreMissingOrEmpty() {
        let provider = OpenRouterProvider().provider
        for totals: [MetricLine]? in [nil, []] {
            let snapshot = snapshot(
                provider, lines: [line("Today", dollars: 50, tokens: 1_000_000)], totals: totals
            )

            let total = TotalSpendAggregator.total(
                for: .today, providers: [provider], snapshots: [provider.id: snapshot]
            )

            XCTAssertTrue(total.isEmpty)
            XCTAssertTrue(total.projection(for: .cost).isEmpty)
            XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        }
    }

    func testMissingDedicatedPeriodDoesNotFallBackToCardRows() {
        let provider = OpenRouterProvider().provider
        let snapshot = snapshot(
            provider,
            lines: [line("Today", dollars: 99, tokens: 9_000_000)],
            totals: [line("Yesterday", dollars: 3, tokens: 600_000)]
        )

        XCTAssertTrue(TotalSpendAggregator.total(
            for: .today, providers: [provider], snapshots: [provider.id: snapshot]
        ).isEmpty)
        let yesterday = TotalSpendAggregator.total(
            for: .yesterday, providers: [provider], snapshots: [provider.id: snapshot]
        )
        XCTAssertEqual(yesterday.totalUSD, 3)
        XCTAssertEqual(yesterday.totalTokens, 600_000)
        XCTAssertTrue(TotalSpendAggregator.total(
            for: .last30, providers: [provider], snapshots: [provider.id: snapshot]
        ).isEmpty)
    }

    func testCostOnlyDedicatedTotalsDoNotBorrowTokensFromCardRows() {
        let provider = OpenRouterProvider().provider
        let snapshot = snapshot(
            provider,
            lines: [line("Today", dollars: 99, tokens: 9_000_000)],
            totals: [line("Today", dollars: 4, tokens: nil)]
        )

        let total = TotalSpendAggregator.total(
            for: .today, providers: [provider], snapshots: [provider.id: snapshot]
        )

        XCTAssertEqual(total.projection(for: .cost).centerValue, 4)
        XCTAssertFalse(total.projection(for: .cost).isEstimated)
        XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testTokenOnlyDedicatedTotalsDoNotBorrowCostFromCardRows() {
        let provider = OpenRouterProvider().provider
        let snapshot = snapshot(
            provider,
            lines: [line("Today", dollars: 99, tokens: 9_000_000)],
            totals: [line("Today", dollars: nil, tokens: 500_000)]
        )

        let total = TotalSpendAggregator.total(
            for: .today, providers: [provider], snapshots: [provider.id: snapshot]
        )

        XCTAssertEqual(total.projection(for: .tokens).centerValue, 500_000)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
    }

    func testLegacySnapshotWithoutDedicatedFieldDecodesAndCannotContributeKeyUsage() throws {
        let provider = OpenRouterProvider().provider
        let original = snapshot(
            provider,
            lines: [line("Today", dollars: 99, tokens: 9_000_000)],
            totals: [line("Today", dollars: 4, tokens: 500_000)]
        )
        var legacy = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        )
        legacy.removeValue(forKey: "totalSpendLines")

        let decoded = try JSONDecoder().decode(
            ProviderSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy)
        )

        XCTAssertEqual(decoded.lines, original.lines)
        XCTAssertNil(decoded.totalSpendLines)
        XCTAssertTrue(TotalSpendAggregator.total(
            for: .today, providers: [provider], snapshots: [provider.id: decoded]
        ).isEmpty)
    }

    func testDedicatedPeriodsSurviveSnapshotCacheReload() throws {
        let provider = OpenRouterProvider().provider
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = now
        let original = snapshot(
            provider,
            lines: [line("Today", dollars: 99, tokens: 9_000_000)],
            totals: [
                line("Today", dollars: 0, tokens: 0),
                line("Yesterday", dollars: 2, tokens: 500_000),
                line("Last 30 Days", dollars: 9, tokens: 1_500_000)
            ]
        )
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache", now: { now }).store(original)

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageKey: "cache", now: { now })
        let cached = try XCTUnwrap(reloaded.loadSnapshots(providerIDs: [provider.id])[provider.id])

        XCTAssertEqual(cached.totalSpendLines, original.totalSpendLines)
        XCTAssertEqual(cached.lines, original.lines)
        XCTAssertNil(cached.usageHistory)
        XCTAssertTrue(TotalSpendAggregator.total(
            for: .today, providers: [provider], snapshots: [provider.id: cached]
        ).isEmpty)
        for (period, cost, tokens): (TotalSpendPeriod, Double, Double) in [
            (.yesterday, 2, 500_000), (.last30, 9, 1_500_000)
        ] {
            let total = TotalSpendAggregator.total(
                for: period, providers: [provider], snapshots: [provider.id: cached]
            )
            XCTAssertEqual(total.totalUSD, cost)
            XCTAssertEqual(total.totalTokens, tokens)
        }
    }

    private func snapshot(
        _ provider: Provider,
        lines: [MetricLine] = [],
        totals: [MetricLine]? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot.make(
            provider: provider, plan: nil, lines: lines, totalSpendLines: totals, refreshedAt: now
        )
    }

    private func line(
        _ label: String,
        dollars: Double?,
        tokens: Double?,
        estimated: Bool = false
    ) -> MetricLine {
        var values: [MetricValue] = []
        if let dollars { values.append(MetricValue(number: dollars, kind: .dollars, estimated: estimated)) }
        if let tokens { values.append(MetricValue(number: tokens, kind: .count, label: "tokens")) }
        return .values(label: label, values: values)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "OpenUsageTests.OpenRouterTotalSpend.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }
}
