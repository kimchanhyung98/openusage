import XCTest
@testable import Egasu

final class UsageCollectionIntegrationTests: XCTestCase {
    private let now = EgasuISO8601.date(from: "2026-11-01T03:00:00Z")!

    func testDefaultRegistryFindsUnmappedClientsAndScopesTheirFailures() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(
            #"{"sessionId":"g","messages":[{"type":"gemini","id":"g1","timestamp":"2026-11-01T01:00:00Z","tokens":{"input":100,"output":20,"total":120}}]}"#,
            to: home.appendingPathComponent(".gemini/tmp/project/chats/session.json")
        )
        let qwen = home.appendingPathComponent(".qwen/projects/project/chats/session.jsonl")
        try UsageRecordFixture.write(
            #"{"type":"assistant","uuid":"q1","sessionId":"q","timestamp":"2026-11-01T01:00:00Z","usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":10,"totalTokenCount":60}}"#,
            to: qwen
        )
        let coordinator = UsageCollectionCoordinator(environment: FakeEnvironment([:]), home: home)
        let collected = await coordinator.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(Set(result.records.map(\.sourceID)), ["gemini", "qwen"])
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 180)
        XCTAssertTrue(result.records.allSatisfy { $0.providerID == nil })
        XCTAssertNil(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        try UsageRecordFixture.write("invalid journal", to: qwen)
        let failedResult = await coordinator.collect(since: .distantPast)
        let partial = try XCTUnwrap(failedResult)
        XCTAssertEqual(partial.readFailureCount, 1)
        XCTAssertEqual(partial.records.count, 1)
        XCTAssertNil(UsageHistoryBuilder.scan(partial, providerID: "claude", since: .distantPast, pricing: .empty))
        await coordinator.flushCache()
    }

    func testOpenClawCodexHomesUseNativeScannerAndStayOutOfAccountCards() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let log = CodexLogFixture.tokenCount(
            timestamp: "2026-11-01T01:00:00Z", last: CodexLogFixture.usage(input: 100, output: 20), model: "gpt-5.2"
        )
        try UsageRecordFixture.write(log, to: home.appendingPathComponent(
            ".openclaw/agents/main/agent/codex-home/sessions/rollout.jsonl"
        ))
        try UsageRecordFixture.write(log, to: home.appendingPathComponent(
            ".openclaw/agents/main/agent/cli-auth/codex/old/sessions/rollout.jsonl"
        ))
        let scanner = CodexLogUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { home },
                                           incrementalScanner: IncrementalJSONLScanner())
        let disabled = await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertNil(disabled)
        let enabled = await scanner.scan(now: now, pricing: TestPricing.bundled, includeSharedHomes: true)
        XCTAssertEqual(enabled?.series.daily.first?.totalTokens, 120)
        let account = CodexLogUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { home },
                                           incrementalScanner: IncrementalJSONLScanner(),
                                           cacheIdentityOverride: "fixture-account", rootsOverride: [])
        let isolated = await account.scan(now: now, pricing: TestPricing.bundled, includeSharedHomes: true)
        XCTAssertNil(isolated)
    }

    func testKimiWorkAndKiroV2ReachExistingStatistics() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        try UsageRecordFixture.write(
            #"{"type":"usage.record","model":"k2d6-agent","usageScope":"session","time":1793494800000,"usage":{"inputOther":100,"output":10,"inputCacheRead":20}}"#,
            to: home.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions/work/ctitle-1/agents/main/wire.jsonl")
        )
        let kimi = KimiUsageScanner(environment: FakeEnvironment([:]), homeDirectory: home)
        let kimiScan = try await kimi.scan(now: now)
        XCTAssertEqual(kimiScan?.series.daily.first?.totalTokens, 130)
        XCTAssertNil(kimiScan?.series.daily.first?.costUSD)
        XCTAssertEqual(kimiScan?.invalidRows, 0)
        try UsageRecordFixture.write(
            #"{"session_id":"s","session_state":{"conversation_metadata":{"user_turn_metadatas":[{"input_token_count":100,"output_token_count":20,"cache_read_input_token_count":30,"end_timestamp":1793494800,"message_ids":["m1"],"metering_usage":[{"unit":"credit","value":0.5}]}]}}}"#,
            to: home.appendingPathComponent(".kiro/sessions/cli/session.json")
        )
        let kiro = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: home)
        let kiroScan = try await kiro.scan(now: now)
        XCTAssertEqual(kiroScan?.daily.first?.tokens, 150)
        XCTAssertEqual(kiroScan?.daily.first?.costUSD, 0.02)
        XCTAssertEqual(kiroScan?.daily.first?.tokensEstimated, false)
    }

    func testUnverifiedDevinDesktopRecordCannotReplaceNativeCLIRequest() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let metadata = #"{"request_id":"r1","created_at":"2026-11-01T01:00:00Z","generation_model":"claude-sonnet-4-6","metrics":{"input_tokens":100,"output_tokens":10,"cache_read_tokens":20}}"#
        let session = home.appendingPathComponent(".local/share/devin/cli/sessions/s")
        try UsageRecordFixture.write(#"{"v":1,"id":"s"}"#, to: session.appendingPathComponent("meta.json"))
        try UsageRecordFixture.write(
            #"{"kind":"node","at":1793494800,"node":{"id":1,"message":{"role":"assistant","metadata":"# + metadata + "}}}\n",
            to: session.appendingPathComponent("log.jsonl")
        )
        let scanner = DevinUsageScanner(environment: FakeEnvironment([:]), homeDirectory: home)
        let nativeScan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(nativeScan?.series.daily.first?.totalTokens, 130)
        let unverifiedMetadata = metadata.replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":1000")
        try UsageRecordFixture.write(
            #"{"providerId":"devin-cli","notification":{"sessionUpdate":"usage_update","metadata":"# + unverifiedMetadata + "}}\n",
            to: home.appendingPathComponent("Library/Application Support/Devin/User/acp-events/session.ndjson")
        )
        let scan = try await scanner.scan(now: now, pricing: TestPricing.bundled)
        XCTAssertEqual(scan?.series.daily.first?.totalTokens, 130)
        XCTAssertEqual(scan?.invalidRows, 1)
        XCTAssertFalse(scan?.warnings.isEmpty == true)
    }

}
