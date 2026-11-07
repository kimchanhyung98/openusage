import XCTest
@testable import Egasu

@MainActor
final class NativeSharedUsageFailureTests: XCTestCase {
    func testClaudeReadFailureSurvivesEmptySharedMergeAndRecovers() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let path = home.appendingPathComponent(".claude/projects/fixture/usage.jsonl")
        try UsageRecordFixture.write(ClaudeLogFixture.usageLine(
            timestamp: EgasuISO8601.string(from: now), input: 3, output: 2,
            messageID: "message", requestID: "request"
        ) + "\n", to: path)
        let scanner = ClaudeLogUsageScanner(environment: FakeEnvironment(), homeDirectory: { home },
                                            incrementalScanner: IncrementalJSONLScanner())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: path.path))

        let failed = await scanner.scan(now: now, pricing: .empty)
        try verifyFailedMerge(failed, providerID: "claude", now: now)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let recovered = await scanner.scan(now: now, pricing: .empty)
        XCTAssertEqual(recovered?.readFailureCount, 0)
        XCTAssertEqual(recovered?.usageHistory?.series.daily.first?.totalTokens, 5)
        XCTAssertNil(recovered?.readWarning)
    }

    func testCodexReadFailureSurvivesEmptySharedMergeAndRecovers() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date()
        let path = home.appendingPathComponent(".codex/sessions/fixture/rollout.jsonl")
        try UsageRecordFixture.write(CodexLogFixture.tokenCount(
            timestamp: EgasuISO8601.string(from: now),
            last: CodexLogFixture.usage(input: 3, output: 2), model: "fixture-model"
        ) + "\n", to: path)
        let scanner = CodexLogUsageScanner(environment: FakeEnvironment(), homeDirectory: { home },
                                           incrementalScanner: IncrementalJSONLScanner())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path) }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: path.path))

        let failed = await scanner.scan(now: now, pricing: .empty)
        try verifyFailedMerge(failed, providerID: "codex", now: now)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let recovered = await scanner.scan(now: now, pricing: .empty)
        XCTAssertEqual(recovered?.readFailureCount, 0)
        XCTAssertEqual(recovered?.usageHistory?.series.daily.first?.totalTokens, 5)
        XCTAssertNil(recovered?.readWarning)
    }

    private func verifyFailedMerge(_ native: LogUsageScan?, providerID: String, now: Date) throws {
        let native = try XCTUnwrap(native)
        XCTAssertEqual(native.readFailureCount, 1)
        let completed = UsageCollection(records: [], sources: [.init(sourceID: "pi", completedStores: 1)])
        let shared = try XCTUnwrap(UsageHistoryBuilder.scan(
            completed, providerID: providerID, since: .distantPast, pricing: .empty
        ))
        XCTAssertNotNil(shared.usageHistory)
        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([native, shared]))
        XCTAssertEqual(merged.readFailureCount, 1)
        XCTAssertNil(merged.usageHistory)
        XCTAssertEqual(merged.readWarning, "Some local usage files could not be read. Usage history may be incomplete.")

        var normal = DailyUsageAccumulator()
        normal.add(day: DailyUsageAccumulator.dayKey(from: now), tokens: 7, cost: 0.02, model: "shared-model")
        let partial = try XCTUnwrap(DailyUsageAccumulator.merged([native, normal.build()]))
        XCTAssertEqual(partial.usageHistory?.series.daily.first?.totalTokens, 7)
        XCTAssertEqual(partial.readFailureCount, 1)
        XCTAssertNotNil(partial.readWarning)
    }
}
