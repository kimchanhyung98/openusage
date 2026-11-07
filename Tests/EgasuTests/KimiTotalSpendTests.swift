import Foundation
import os
import XCTest
@testable import Egasu

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
        XCTAssertNil(snapshot.warning)
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

    func testCurrentQuotaResponseStillCollectsLocalTokens() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root)
        let provider = makeProvider(root: root, usageJSON: #"""
        {"goods_version":2,"usages":{"limit_5h":{"used_ratio":0.3},"limit_7d":{"used_ratio":"0.2"}}}
        """#)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertEqual(tokens(snapshot), 190)
    }

    func testStoreRetainsSameDayTotalsOnFullHistoryFailureThenRecoversAndAcceptsEmptyHistory() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root)
        let clock = OSAllocatedUnfairLock(initialState: now)
        let provider = makeProvider(root: root, clock: clock)
        let suite = "KimiTotalSpendTests.retention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { clock.withLock { $0 } })
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache,
                                    defaults: defaults, now: { clock.withLock { $0 } })
        await store.refreshAll(force: true)
        let previous = try XCTUnwrap(store.localSnapshots["kimi"])
        XCTAssertEqual(tokens(previous), 190)
        XCTAssertEqual(previous.totalSpendRefreshedAt, now)

        let refreshedNow = now.addingTimeInterval(60)
        clock.withLock { $0 = refreshedNow }
        try writeHistory(root: root, version: "unsupported-version")
        await store.refreshAll(force: true)
        let retained = try XCTUnwrap(store.localSnapshots["kimi"])
        XCTAssertEqual(retained.totalSpendLines, previous.totalSpendLines)
        XCTAssertEqual(retained.totalSpendRefreshedAt, now)
        XCTAssertTrue(retained.warning?.contains("unsupported format") == true)
        XCTAssertNil(store.providerErrors["kimi"])
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["kimi"])["kimi"]?.totalSpendLines, previous.totalSpendLines)

        let wire = root.appendingPathComponent("sessions/workspace/session/agents/main/wire.jsonl")
        try Data().write(to: wire)
        let work = root.appendingPathComponent(
            "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/work/conv-1/agents/main/wire.jsonl"
        )
        try UsageRecordFixture.write("not-json\n", to: work)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.localSnapshots["kimi"]?.totalSpendLines, previous.totalSpendLines)
        XCTAssertEqual(store.localSnapshots["kimi"]?.totalSpendRefreshedAt, now)
        XCTAssertEqual(store.localSnapshots["kimi"]?.refreshedAt, refreshedNow)
        XCTAssertEqual(store.localSnapshots["kimi"]?.isDegraded, true)
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["kimi"])["kimi"]?.totalSpendRefreshedAt, now)
        XCTAssertNil(store.headerNotice(for: "kimi"))
        try FileManager.default.removeItem(at: work)

        try writeHistory(root: root, cacheWrites: 0)
        await store.refreshAll(force: true)
        let recovered = try XCTUnwrap(store.localSnapshots["kimi"])
        XCTAssertEqual(tokens(recovered), 150)
        XCTAssertEqual(recovered.totalSpendRefreshedAt, now.addingTimeInterval(60))
        XCTAssertFalse(recovered.warning?.contains("unsupported format") == true)

        try Data().write(to: wire)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.localSnapshots["kimi"]?.totalSpendLines, [])
        XCTAssertNil(store.localSnapshots["kimi"]?.warning)

        try writeHistory(root: root)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.localSnapshots["kimi"].map(tokens), 190)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        clock.withLock { $0 = nextDay }
        try writeHistory(root: root, version: "unsupported-version")
        await store.refreshAll(force: true)
        XCTAssertNil(store.localSnapshots["kimi"]?.totalSpendLines)
        XCTAssertNil(store.localSnapshots["kimi"]?.totalSpendRefreshedAt)
        XCTAssertTrue(store.localSnapshots["kimi"]?.warning?.contains("unsupported format") == true)
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
        let message = "Kimi Code usage history uses an unsupported format. Check for an egasu update."

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertEqual(snapshot.warning, message)
        XCTAssertEqual(snapshot.warningPresentation, [LocalizedMessage(message)])
        XCTAssertEqual(snapshot.isDegraded, true)
    }

    func testMalformedHistoryKeepsValidTokensWithoutCardWarning() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHistory(root: root, suffix: "invalid-json\n")
        let snapshot = await makeProvider(root: root).refresh()

        XCTAssertEqual(tokens(snapshot), 190)
        XCTAssertNil(snapshot.warning)
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

    func testFirstRefreshUsesCustomHistoryFromColdLoginShell() async throws {
        for hasDefaultHistory in [false, true] {
            let root = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let customHome = root.appendingPathComponent("custom")
            try writeHistory(root: customHome)
            if hasDefaultHistory {
                try writeHistory(root: root.appendingPathComponent(".kimi-code"), cacheWrites: 0)
            }
            let shell = LoginShellEnvironment(runner: KimiHistoryShellRunner(stdout: [
                "__EGASU_ENV_BEGIN__", "KIMI_CODE_HOME=\(customHome.path)",
                "PATH=/usr/bin", "__EGASU_ENV_END__"
            ].joined(separator: "\0")))
            let environment = ProcessEnvironmentReader(
                processEnvironment: [:], shellEnvironment: shell, launchSnapshot: { nil }
            )
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertNil(environment.value(for: "KIMI_CODE_HOME"))
            let fixedNow = now
            let provider = KimiProvider(
                authStore: KimiAuthStore(
                    files: FakeFiles([
                        customHome.appendingPathComponent("credentials/kimi-code.json").path:
                            #"{"access_token":"fake-access"}"#
                    ]),
                    environment: environment, homeDirectory: { root }
                ),
                usageClient: KimiUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                    statusCode: 200, headers: [:], body: Data(#"{"usage":{"limit":100,"used":60}}"#.utf8)
                ))), now: { fixedNow }, pricing: { .empty }
            )
            XCTAssertFalse(shell.capturedSuccessfully)

            let snapshot = await provider.refresh()

            XCTAssertTrue(shell.capturedSuccessfully)
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertNotNil(snapshot.line(label: "Weekly"))
            XCTAssertEqual(tokens(snapshot), 190, "default history present: \(hasDefaultHistory)")
        }
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

    private func makeProvider(
        root: URL, status: Int = 200, pricing: ModelPricing = .empty, usageJSON: String? = nil,
        clock: OSAllocatedUnfairLock<Date>? = nil
    ) -> KimiProvider {
        let fixedNow = now
        let currentNow: @Sendable () -> Date = { clock?.withLock { $0 } ?? fixedNow }
        let files = FakeFiles([
            root.appendingPathComponent("credentials/kimi-code.json").path: #"{"access_token":"fake-access"}"#
        ])
        let body = usageJSON ?? #"""
        {"user":{"membership":{"level":"LEVEL_ADVANCED"}},
        "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":100,"used":25}}],
        "usage":{"limit":100,"used":60}}
        """#
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8)))
        return KimiProvider(
            authStore: KimiAuthStore(
                files: files, environment: FakeEnvironment(["KIMI_CODE_HOME": root.path]), homeDirectory: { root }
            ),
            usageClient: KimiUsageClient(http: http, now: currentNow), now: currentNow, pricing: { pricing }
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

private struct KimiHistoryShellRunner: ProcessRunning {
    let stdout: String

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
