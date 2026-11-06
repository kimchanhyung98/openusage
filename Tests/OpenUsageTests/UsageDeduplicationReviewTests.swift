import XCTest
@testable import OpenUsage

final class UsageDeduplicationReviewTests: XCTestCase {
    func testSymlinkParentSessionDeduplicatesForkWithoutMergingIndependentSession() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual")
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let usage = #"{"type":"message","id":"m1","timestamp":"2026-11-01T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"test-model","usage":{"input":100,"output":20,"cost":{"total":0.5}}}}"#
        try UsageRecordFixture.write(#"{"type":"session","id":"parent"}"# + "\n" + usage,
                                     to: actual.appendingPathComponent("parent.jsonl"))
        let parentPath = alias.appendingPathComponent("parent.jsonl").path
        let childHeader = try JSONSerialization.data(withJSONObject: ["type": "session", "id": "child", "parentSession": parentPath])
        try UsageRecordFixture.write(childHeader + Data(("\n" + usage).utf8), to: actual.appendingPathComponent("child.jsonl"))
        try UsageRecordFixture.write(#"{"type":"session","id":"independent"}"# + "\n" + usage,
                                     to: actual.appendingPathComponent("independent.jsonl"))
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [actual, alias], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" },
            parse: { try PiSessionParser.parse($0, path: $1, sourceID: "pi") }
        )
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 2)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 240)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 1)
    }
}
