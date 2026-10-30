import XCTest
@testable import OpenUsage

@MainActor
final class AntigravityUsageIntegrationTests: XCTestCase {
    private let fixedNow = Date(timeIntervalSince1970: 1_793_318_400)

    func testRefreshCombinesQuotaAndLocalHistoryForEachRingPeriod() async throws {
        let scan = usageScan()
        let now = fixedNow
        let provider = makeProvider(usageScan: { observedAt, pricing in
            XCTAssertEqual(observedAt, now)
            XCTAssertTrue(pricing === ModelPricing.empty)
            return scan
        })

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.refreshedAt, now)
        XCTAssertEqual(snapshot.usageHistory, scan.usageHistory)
        XCTAssertEqual(snapshot.lines.compactMap { line -> String? in
            guard case .progress = line else { return nil }
            return line.label
        }, ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertNil(snapshot.warning)
        XCTAssertFalse(snapshot.lines.contains(where: \.isError))

        let expectations: [(TotalSpendPeriod, Double, Double)] = [
            (.today, 1.25, 100), (.yesterday, 2.5, 200), (.last30, 7.75, 600)
        ]
        for (period, dollars, tokens) in expectations {
            let total = TotalSpendAggregator.total(
                for: period, providers: [provider.provider], snapshots: [provider.provider.id: snapshot]
            )
            XCTAssertEqual(total.projection(for: .cost).centerValue, dollars, accuracy: 0.000_001)
            XCTAssertEqual(total.projection(for: .tokens).centerValue, tokens, accuracy: 0.000_001)
            XCTAssertTrue(total.projection(for: .cost).isEstimated)
        }
    }

    func testLocalUsageRemainsVisibleAndCachedWhenQuotaFetchFails() async throws {
        let scan = usageScan()
        let provider = makeProvider(usageScan: { _, _ in scan }, quotaAvailable: false)
        let fixture = makeStore(provider)

        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots[provider.provider.id])
        XCTAssertEqual(snapshot.usageHistory, scan.usageHistory)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertFalse(snapshot.lines.contains(where: \.isError))
        XCTAssertFalse(snapshot.lines.contains { if case .progress = $0 { return true }; return false })
        XCTAssertTrue(try XCTUnwrap(snapshot.warning).contains(AntigravityError.unavailable.localizedDescription))
        XCTAssertNotNil(fixture.store.headerNotice(for: provider.provider.id))
        XCTAssertNil(fixture.store.errorMessage(for: provider.provider.id))
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: [provider.provider.id])[provider.provider.id], snapshot)

        let total = TotalSpendAggregator.total(
            for: .today, providers: [provider.provider], snapshots: fixture.store.snapshots
        )
        XCTAssertEqual(total.projection(for: .cost).centerValue, 1.25, accuracy: 0.000_001)

        let document = fixture.store.localHistoryDocument(
            deviceID: "fixture-mac", deviceName: "Fixture Mac", updatedAt: fixedNow
        )
        XCTAssertEqual(document.providers[provider.provider.id], scan.usageHistory)
        XCTAssertNil(document.identities?[provider.provider.id])
    }

    func testUnpricedModelsShowHeaderWarningWhileKnownUsageRemainsInRing() async throws {
        let day = DailyUsageAccumulator.dayKey(from: fixedNow)
        let scan = LogUsageScan(
            series: usageScan().series,
            unknownModelsByDay: [day: ["unpriced-synthetic-model"]]
        )
        let provider = makeProvider(usageScan: { _, _ in scan })
        let fixture = makeStore(provider)

        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots[provider.provider.id])
        let warning = "Some Antigravity models have no price. Their usage is excluded from totals."
        XCTAssertEqual(fixture.store.headerNotice(for: provider.provider.id), L10n.errors(warning))
        XCTAssertNil(fixture.store.errorMessage(for: provider.provider.id))
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertEqual(snapshot.usageHistory, scan.usageHistory)
        XCTAssertNotNil(snapshot.line(label: "Session"))

        let total = TotalSpendAggregator.total(
            for: .today, providers: [provider.provider], snapshots: fixture.store.snapshots
        )
        XCTAssertEqual(total.projection(for: .cost).centerValue, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(total.projection(for: .tokens).centerValue, 100, accuracy: 0.000_001)
    }

    func testOnlyUnpricedModelsShowHeaderWarningAndClearPreviousRingTotals() async throws {
        let day = DailyUsageAccumulator.dayKey(from: fixedNow)
        let scan = LogUsageScan(
            series: DailyUsageSeries(daily: []),
            unknownModelsByDay: [day: ["unpriced-synthetic-model"]]
        )
        let sequence = UsageScanSequence([usageScan(), scan])
        let provider = makeProvider(usageScan: { _, _ in await sequence.next() })
        let fixture = makeStore(provider)

        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)
        XCTAssertNotNil(fixture.store.localSnapshots[provider.provider.id]?.line(label: "Today"))
        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots[provider.provider.id])
        let warning = "Some Antigravity models have no price. Their usage is excluded from totals."
        XCTAssertEqual(fixture.store.headerNotice(for: provider.provider.id), L10n.errors(warning))
        XCTAssertNil(fixture.store.errorMessage(for: provider.provider.id))
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertEqual(snapshot.usageHistory, scan.usageHistory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        for period in TotalSpendPeriod.allCases {
            XCTAssertNil(snapshot.line(label: period.lineLabel))
            let total = TotalSpendAggregator.total(
                for: period, providers: [provider.provider], snapshots: fixture.store.snapshots
            )
            XCTAssertTrue(total.projection(for: .cost).isEmpty)
            XCTAssertTrue(total.projection(for: .tokens).isEmpty)
        }
    }

    func testQuotaRefreshSurvivesLocalScanFailureWithWarning() async throws {
        let provider = makeProvider(usageScan: { _, _ in throw LocalScanFailure() })

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertFalse(snapshot.lines.contains(where: \.isError))
    }

    func testMissingScanPreservesHistoryButCompletedEmptyScanClearsIt() async throws {
        let scan = usageScan()
        let empty = LogUsageScan(series: DailyUsageSeries(daily: []), unknownModelsByDay: [:])
        let sequence = UsageScanSequence([scan, nil, empty])
        let provider = makeProvider(usageScan: { _, _ in await sequence.next() })
        let fixture = makeStore(provider)

        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)
        XCTAssertEqual(fixture.store.localSnapshots[provider.provider.id]?.usageHistory, scan.usageHistory)

        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)
        XCTAssertEqual(fixture.store.localSnapshots[provider.provider.id]?.usageHistory, scan.usageHistory)
        XCTAssertNotNil(fixture.store.localSnapshots[provider.provider.id]?.line(label: "Today"))

        _ = await fixture.store.refresh(providerID: provider.provider.id, force: true)
        let snapshot = try XCTUnwrap(fixture.store.localSnapshots[provider.provider.id])
        XCTAssertEqual(snapshot.usageHistory, empty.usageHistory)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Last 30 Days"))
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: [provider.provider.id])[provider.provider.id], snapshot)
    }

    func testMissingOrEmptyLocalUsageDoesNotHideQuotaFailure() async {
        let empty = LogUsageScan(series: DailyUsageSeries(daily: []), unknownModelsByDay: [:])
        for scan in [nil, empty] as [LogUsageScan?] {
            let provider = makeProvider(usageScan: { _, _ in scan }, quotaAvailable: false)

            let snapshot = await provider.refresh()

            XCTAssertTrue(snapshot.lines.allSatisfy(\.isError))
            XCTAssertEqual(snapshot.errorCategory, .network)
            XCTAssertNil(snapshot.line(label: "Today"))
        }
    }

    func testQuotaFailureAndUnreadableLocalHistoryRemainAnError() async {
        let provider = makeProvider(
            usageScan: { _, _ in throw LocalScanFailure() }, quotaAvailable: false
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.allSatisfy(\.isError))
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.line(label: "Today"))
    }

    private func makeProvider(
        usageScan: @escaping @Sendable (Date, ModelPricing) async throws -> LogUsageScan?,
        quotaAvailable: Bool = true
    ) -> AntigravityProvider {
        let summary = """
        {"groups":[{"buckets":[
          {"bucketId":"gemini-5h","remainingFraction":0.75},
          {"bucketId":"gemini-weekly","remainingFraction":0.9},
          {"bucketId":"3p-5h","remainingFraction":0.4},
          {"bucketId":"3p-weekly","remainingFraction":1}
        ]}]}
        """
        let http = RoutingHTTPClient { request in
            guard quotaAvailable else {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            if request.url.path == AntigravityUsageClient.quotaSummaryPath {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(summary.utf8))
            }
            if request.url.path == AntigravityUsageClient.loadCodeAssistPath {
                return HTTPResponse(
                    statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"id":"g1-pro-tier"}}"#.utf8)
                )
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let token = #"{"token":{"access_token":"fixture-token","expiry":"2099-01-01T00:00:00Z"}}"#
        let now = fixedNow
        return AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(token), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: UsageEmptyProcessRunner()),
            usageScan: usageScan,
            now: { now },
            pricing: { .empty }
        )
    }

    private func usageScan() -> LogUsageScan {
        let days = [0, -1, -2].map { offset in
            DailyUsageAccumulator.dayKey(from: Calendar.current.date(byAdding: .day, value: offset, to: fixedNow)!)
        }
        return LogUsageScan(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: days[0], totalTokens: 100, costUSD: 1.25),
            DailyUsageEntry(date: days[1], totalTokens: 200, costUSD: 2.5),
            DailyUsageEntry(date: days[2], totalTokens: 300, costUSD: 4)
        ]), unknownModelsByDay: [:])
    }

    private func makeStore(_ provider: AntigravityProvider) -> (store: WidgetDataStore, cache: ProviderSnapshotCache) {
        let suite = "AntigravityUsageIntegrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let now = fixedNow
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([provider]),
            providers: [provider],
            cache: cache,
            defaults: defaults,
            now: { now }
        )
        return (store, cache)
    }
}

private struct LocalScanFailure: Error, LocalizedError {
    var errorDescription: String? { "The fixture Antigravity history could not be read." }
}

private struct UsageEmptyProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private actor UsageScanSequence {
    private var scans: [LogUsageScan?]

    init(_ scans: [LogUsageScan?]) { self.scans = scans }

    func next() -> LogUsageScan? { scans.removeFirst() }
}
