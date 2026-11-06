import XCTest
@testable import OpenUsage

final class UsageCollectionIntegrationTests: XCTestCase {
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

}
