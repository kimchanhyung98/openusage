import XCTest
@testable import OpenUsage

final class UsageCollectionIntegrationTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-11-01T03:00:00Z")!

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
}
