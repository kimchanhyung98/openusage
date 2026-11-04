import Foundation
import os
import XCTest
@testable import OpenUsage

@MainActor
final class KimiTotalSpendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefreshAddsTokenOnlyDedicatedTotalsWithoutChangingQuotaMetrics() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root)
        let provider = makeProvider(root: root)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.warning?.contains("Affected periods show tokens only") == true)
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), ["kimi.session", "kimi.weekly"])
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.plan, "Allegro")
        XCTAssertTrue(provider.provider.usesDedicatedSpendLines)
        XCTAssertNil(snapshot.usageHistory)
        let total = TotalSpendAggregator.total(
            for: .today, providers: [provider.provider], snapshots: ["kimi": snapshot]
        )
        XCTAssertEqual(total.totalTokens, 190)
        XCTAssertTrue(total.projection(for: .cost).isEmpty)
        XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
        XCTAssertEqual(total.projection(for: .tokens).centerValue, 190)
        XCTAssertFalse(total.isEstimated)
    }

    func testQuotaFailurePreservesFailureSoTheStoreKeepsLastGoodQuota() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root)
        let provider = makeProvider(root: root, status: 503)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .http5xx)
        XCTAssertEqual(snapshot.lines.map(\.label), [MetricLine.errorBadgeLabel])
        XCTAssertNil(snapshot.totalSpendLines)
    }

    func testVerifiedRequestUsesInjectedPricingAndMarksCostAsEstimated() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root, protocolName: "anthropic", effort: "high", cacheWrites: 0)
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "kimi-k3": ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1)
            ]), primary: PricingCatalog(), secondary: PricingCatalog()
        )
        let provider = makeProvider(root: root, pricing: pricing)
        let snapshot = await provider.refresh()
        let total = TotalSpendAggregator.total(for: .today, providers: [provider.provider], snapshots: ["kimi": snapshot])

        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(total.totalTokens, 150)
        XCTAssertEqual(total.totalUSD, 0.000143, accuracy: 0.0000001)
        XCTAssertTrue(total.isEstimated)
        XCTAssertFalse(total.projection(for: .costPerMtok).isEmpty)
    }

    func testDedicatedTotalsUseTodayYesterdayAndTheFullHistoryWindow() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let midnight = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: midnight)!
        let firstDay = Calendar.current.date(byAdding: .day, value: -30, to: midnight)!
        let outside = firstDay.addingTimeInterval(-1)
        let records = [(yesterday, 17), (firstDay, 29), (outside, 1_000), (now.addingTimeInterval(1), 2_000)]
        let suffix = records.map { date, tokens in
            """
            {"type":"usage.record","agentId":"main","model":"kimi-code/k3","time":\(Int(date.timeIntervalSince1970 * 1_000)),"usage":{"inputOther":\(tokens),"output":0,"inputCacheRead":0,"inputCacheCreation":0}}

            """
        }.joined()
        try writeHistory(root: root, suffix: suffix)
        let provider = makeProvider(root: root)
        let snapshot = await provider.refresh()

        for (period, expected): (TotalSpendPeriod, Double) in [(.today, 190), (.yesterday, 17), (.last30, 236)] {
            let total = TotalSpendAggregator.total(
                for: period, providers: [provider.provider], snapshots: ["kimi": snapshot]
            )
            XCTAssertEqual(total.totalTokens, expected, period.rawValue)
            XCTAssertTrue(total.projection(for: .cost).isEmpty)
            XCTAssertTrue(total.projection(for: .costPerMtok).isEmpty)
        }
    }

    func testQuotaRequestCrossingMidnightUsesTheCompletedSnapshotDateForTotals() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let midnight = Calendar.current.startOfDay(for: now)
        let before = midnight.addingTimeInterval(-1)
        let after = midnight.addingTimeInterval(1)
        let clock = OSAllocatedUnfairLock(initialState: before)
        let suffix = """
        {"type":"usage.record","agentId":"main","model":"kimi-code/k3","time":\(Int(after.timeIntervalSince1970 * 1_000)),"usage":{"inputOther":13,"output":0,"inputCacheRead":0,"inputCacheCreation":0}}

        """
        try writeHistory(root: root, suffix: suffix, date: before)
        let http = RoutingHTTPClient { _ in
            clock.withLock { $0 = after }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"usage":{"limit":100,"used":60}}"#.utf8))
        }
        let provider = KimiProvider(
            authStore: KimiAuthStore(
                files: FakeFiles([root.appendingPathComponent("credentials/kimi-code.json").path: #"{"access_token":"fake-access"}"#]),
                environment: FakeEnvironment(["KIMI_CODE_HOME": root.path]), homeDirectory: { root }
            ),
            usageClient: KimiUsageClient(http: http), now: { clock.withLock { $0 } }, pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.refreshedAt, after)
        for (period, expected): (TotalSpendPeriod, Double) in [(.today, 13), (.yesterday, 190), (.last30, 203)] {
            let total = TotalSpendAggregator.total(
                for: period, providers: [provider.provider], snapshots: ["kimi": snapshot]
            )
            XCTAssertEqual(total.totalTokens, expected, period.rawValue)
        }
    }

    func testHistoryReadErrorPreservesQuotaAndShowsWarning() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("sessions"))
        let snapshot = await makeProvider(root: root).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertTrue(snapshot.warning?.contains("usage history could not be read") == true)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testUnsupportedHistoryFormatPreservesQuotaAndExplainsTheWarning() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root, version: "2.0")
        let snapshot = await makeProvider(root: root).refresh()
        let message = "Kimi Code usage history uses an unsupported format. Check for an OpenUsage update."

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertEqual(snapshot.warning, message)
        XCTAssertEqual(snapshot.warningPresentation, [LocalizedMessage(message)])
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testMalformedHistoryWarnsAndKeepsValidTokens() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root, suffix: "invalid-json\n")
        let snapshot = await makeProvider(root: root).refresh()

        XCTAssertEqual(tokens(snapshot), 190)
        XCTAssertTrue(snapshot.warning?.contains("records are invalid") == true)
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testQuotaAloneNeverCreatesTokenTotals() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = await makeProvider(root: root).refresh()

        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
    }

    func testCapabilityRespectsEnablementEvenWhenAllQuotaRowsAreHidden() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = makeProvider(root: root)
        let suite = "KimiTotalSpendTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = WidgetRegistry.from([runtime])
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.setEnabled(true, for: "kimi")
        let layout = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout",
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        for descriptor in registry.descriptors { layout.setMetricEnabled(descriptor.id, false) }

        XCTAssertTrue(layout.hasSpendCapableProvider)
        XCTAssertEqual(layout.spendCapableProviders.map(\.id), ["kimi"])
        XCTAssertTrue(layout.displayGroups.isEmpty)
        enablement.setEnabled(false, for: "kimi")
        XCTAssertFalse(layout.hasSpendCapableProvider)
    }

    private func tokens(_ snapshot: ProviderSnapshot) -> Double {
        TotalSpendAggregator.total(
            for: .today, providers: [KimiProvider().provider], snapshots: ["kimi": snapshot]
        ).totalTokens
    }

    private func makeProvider(root: URL, status: Int = 200, pricing: ModelPricing = .empty) -> KimiProvider {
        let fixedNow = now
        let files = FakeFiles([
            root.appendingPathComponent("credentials/kimi-code.json").path: #"{"access_token":"fake-access"}"#
        ])
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: status, headers: [:], body: Data(#"""
        {"user":{"membership":{"level":"LEVEL_ADVANCED"}},
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":25}}],
        "usage":{"limit":100,"used":60}}
        """#.utf8)))
        return KimiProvider(
            authStore: KimiAuthStore(
                files: files, environment: FakeEnvironment(["KIMI_CODE_HOME": root.path]), homeDirectory: { root }
            ),
            usageClient: KimiUsageClient(http: http, now: { fixedNow }), now: { fixedNow }, pricing: { pricing }
        )
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-total-spend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeHistory(
        root: URL, suffix: String = "", protocolName: String = "openai", effort: String? = nil, cacheWrites: Int = 40,
        date: Date? = nil, version: String = "1.5"
    ) throws {
        let path = root.appendingPathComponent("sessions/workspace/session/agents/main/wire.jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let thinking = effort.map { ",\"thinkingEffort\":\"\($0)\"" } ?? ""
        let timestamp = Int((date ?? now).timeIntervalSince1970 * 1_000)
        let text = """
        {"type":"metadata","protocol_version":"\(version)","created_at":\(timestamp)}
        {"type":"llm.request","agentId":"main","kind":"loop","provider":"\(protocolName)","modelAlias":"kimi-code/k3","model":"k3"\(thinking)}
        {"type":"usage.record","agentId":"main","model":"kimi-code/k3","usageScope":"turn","time":\(timestamp),"usage":{"inputOther":100,"output":20,"inputCacheRead":30,"inputCacheCreation":\(cacheWrites)}}

        """
        try Data((text + suffix).utf8).write(to: path)
    }
}
