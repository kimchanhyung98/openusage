import XCTest
@testable import OpenUsage

final class NumericReviewRegressionTests: XCTestCase {
    func testInvalidTotalsWithValidLastUsageDoNotDoubleCountRecovery() {
        let data = Data("""
        {"timestamp":"2026-09-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.4","total_token_usage":{"input_tokens":100}}}}
        {"timestamp":"2026-09-12T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.4","total_token_usage":{"input_tokens":-1},"last_token_usage":{"input_tokens":50}}}}
        {"timestamp":"2026-09-12T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model":"gpt-5.4","total_token_usage":{"input_tokens":200}}}}
        """.utf8)
        let scan = CodexLogUsageScanner.aggregate(events: CodexLogUsageScanner.parseFile(data), since: .distantPast, pricing: TestPricing.bundled)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
    }

    func testInvalidTotalsAfterZeroBaselineStillWarn() {
        let data = Data("""
        {"timestamp":"2026-09-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0}}}}
        {"timestamp":"2026-09-12T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":-1}}}}
        """.utf8)
        let scan = CodexLogUsageScanner.aggregate(events: CodexLogUsageScanner.parseFile(data), since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
        XCTAssertNil(scan.usageHistory)
        XCTAssertNotNil(scan.numericWarning)
    }

    func testClaudeInvalidCostsCannotHideValidSidechainCopies() throws {
        for cost in ["-5", "true", "false", "\"bad\""] {
            let bad = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(claudeLine(cost: cost, sidechain: false)))
            let good = try XCTUnwrap(ClaudeLogUsageScanner.parseLine(claudeLine(cost: "0.5", sidechain: true)))
            XCTAssertTrue(bad.invalidNumericValues, cost)
            for entries in [[bad, good], [good, bad]] {
                let scan = ClaudeLogUsageScanner.aggregate(entries: ClaudeLogUsageScanner.dedup(entries), since: .distantPast, pricing: .empty)
                XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
                XCTAssertEqual(scan.series.daily.first?.costUSD, 0.5)
                XCTAssertEqual(scan.rejectedNumericRows, 0)
            }
        }
    }

    func testPiInvalidFirstCopyCannotHideValidUsage() throws {
        func entry(_ input: Int) throws -> PiUsageScanner.Entry {
            try XCTUnwrap(PiUsageScanner.parseLine(Data("""
            {"type":"message","id":"same","timestamp":"2026-09-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":\(input),"totalTokens":100,"cost":{"total":0.5}}}}
            """.utf8)))
        }
        let good = try entry(100), bad = try entry(-1)
        for entries in [[bad, good], [good, bad]] {
            let scan = PiUsageScanner.aggregate(entries: PiUsageScanner.dedup(entries), cardID: "claude", since: .distantPast, pricing: .empty)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
            XCTAssertEqual(scan.rejectedNumericRows, 0)
        }
    }

    func testNegativeCostRejectsTokensAndCostTogether() {
        var accumulator = DailyUsageAccumulator()
        accumulator.add(day: "2026-09-12", tokens: 100, cost: 0.5, model: "a")
        accumulator.add(day: "2026-09-12", tokens: 999, cost: -5, model: "a")
        let scan = accumulator.build()
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.5)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
    }

    @MainActor
    func testInvalidOnlyRefreshPreservesPreviouslyPublishedHistory() async throws {
        let date = Date(timeIntervalSince1970: 1_789_200_000)
        var good = DailyUsageAccumulator()
        good.add(day: "2026-09-12", tokens: 100, cost: 0.5, model: "gpt-5.4")
        let history = good.build().usageHistory
        let rejected = CodexLogUsageScanner.aggregate(events: CodexLogUsageScanner.parseFile(Data(#"{"timestamp":"2026-09-12T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":-1}}}}"#.utf8)), since: .distantPast, pricing: .empty)
        let codex = CodexProvider()
        let provider = codex.provider
        let runtime = TogglingProviderRuntime(provider: provider, descriptors: codex.widgetDescriptors,
            first: .init(providerID: provider.id, displayName: provider.displayName, lines: [], refreshedAt: date, usageHistory: history),
            second: .init(providerID: provider.id, displayName: provider.displayName,
                          lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                          refreshedAt: date, usageHistory: rejected.usageHistory, warning: rejected.numericWarning))
        let suite = "NumericReviewTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(registry: WidgetRegistry(providers: [provider], descriptors: codex.widgetDescriptors),
                                    providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
                                    defaults: defaults, now: { date })
        await store.refreshAll(force: true)
        XCTAssertEqual(store.snapshots[provider.id]?.usageHistory, history)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.snapshots[provider.id]?.usageHistory, history)
        XCTAssertEqual(store.warningMessage(for: provider.id), rejected.numericWarning)
        XCTAssertNotNil(store.snapshots[provider.id]?.line(label: "Session"))
    }

    func testOldMalformedGrokModelEventsDoNotPreventAnAuthoritativeEmptyWindow() throws {
        let since = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-12T00:00:00Z"))
        let old = #"{"ts":"2026-08-01T00:00:00Z","pid":1e300,"msg":"model changed","ctx":{"model":"grok-build"}}"#
        let empty = GrokLogUsageScanner.parse(old, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(empty.rejectedNumericRows, 0)
        XCTAssertNotNil(empty.usageHistory)
        XCTAssertTrue(empty.series.daily.isEmpty)
        XCTAssertNil(empty.numericWarning)
        let current = #"{"ts":"2026-09-12T10:00:00Z","pid":1e300,"msg":"shell.turn.inference_done","ctx":{"prompt_tokens":100}}"#
        let rejected = GrokLogUsageScanner.parse(old + "\n" + current, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(rejected.rejectedNumericRows, 1)
        XCTAssertNil(rejected.usageHistory)
        let known = #"{"ts":"2026-08-01T00:00:00Z","pid":1,"msg":"model changed","ctx":{"model":"grok-build"}}"#
        let valid = current.replacingOccurrences(of: "1e300", with: "1")
        let recovered = GrokLogUsageScanner.parse(old + "\n" + known + "\n" + valid, since: since, pricing: TestPricing.bundled)
        XCTAssertEqual(recovered.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(recovered.rejectedNumericRows, 0)
    }

    private func claudeLine(cost: String, sidechain: Bool) -> Data {
        Data("""
        {"timestamp":"2026-09-12T10:00:00Z","sessionId":"s","requestId":"r","version":"1.0.24","isSidechain":\(sidechain),"costUSD":\(cost),"message":{"id":"same","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":0}}}
        """.utf8)
    }
}
