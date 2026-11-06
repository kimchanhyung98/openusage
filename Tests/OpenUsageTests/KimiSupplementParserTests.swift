import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class KimiSupplementParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testCompletedUsageSurvivesPartialAppendAndMalformedRowsForBothWireFormats() async throws {
        for work in [true, false] {
            let root = try UsageRecordFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let path = root.appendingPathComponent("wire.jsonl")
            let first = try row(work: work, id: "first", input: 100) + Data([0x0A])
            let second = try row(work: work, id: "second", input: 200)
            let collector = UsageFileCollector(
                sourceID: work ? "kimi-work" : "kimi-cli", roots: [root], scanner: IncrementalJSONLScanner(),
                includeFile: { $0.lastPathComponent == "wire.jsonl" },
                parse: { try KimiSupplementParser.parse($0, path: $1, work: work) }
            )
            try UsageRecordFixture.write(first, to: path)
            let initial = await collector.collect(since: .distantPast)
            XCTAssertEqual(initial?.records.map(\.totalTokens), [130])

            try UsageRecordFixture.write(first + second.prefix(second.count / 2), to: path)
            let pending = await collector.collect(since: .distantPast)
            XCTAssertEqual(pending?.readFailureCount, 0)
            XCTAssertEqual(pending?.records.map(\.totalTokens), [130])

            try UsageRecordFixture.write(first + second, to: path)
            let completed = await collector.collect(since: .distantPast)
            XCTAssertEqual(completed?.records.map(\.totalTokens), [130, 230])

            try UsageRecordFixture.write(first + Data("not-json\n".utf8) + second + Data([0x0A]), to: path)
            let malformed = await collector.collect(since: .distantPast)
            XCTAssertEqual(malformed?.readFailureCount, 0)
            XCTAssertEqual(malformed?.records.filter { $0.issues.isEmpty }.map(\.totalTokens), [130, 230])
            XCTAssertEqual(malformed?.records.filter { $0.issues.contains(.invalidMetadata) }.count, 1)
        }
    }

    func testLegacyMessageIDsDoNotClaimAProviderOrProveCrossSessionForkLineage() throws {
        let data = try row(work: false, id: "01966c94-8738-7a62-a25a-4f97a59721ad", input: 100)
        let original = try KimiSupplementParser.parse(data, path: "/fixture/original/wire.jsonl", work: false)
        let other = try KimiSupplementParser.parse(data, path: "/fixture/other/wire.jsonl", work: false)
        let records = UsageRecordDeduplicator.records(original + other)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.map(\.totalTokens), [130, 130])
        XCTAssertTrue(records.allSatisfy { $0.providerID == nil && $0.responseID == nil && $0.parentSession == nil })
    }

    private func row(work: Bool, id: String, input: Int) throws -> Data {
        let object: [String: Any]
        if work {
            object = [
                "type": "usage.record", "id": id, "time": Int(now.timeIntervalSince1970 * 1_000),
                "usage": ["inputOther": input, "output": 10, "inputCacheRead": 20, "inputCacheCreation": 0]
            ]
        } else {
            object = [
                "timestamp": now.timeIntervalSince1970,
                "message": ["type": "StatusUpdate", "payload": [
                    "message_id": id,
                    "token_usage": ["input_other": input, "output": 10, "input_cache_read": 20, "input_cache_creation": 0]
                ]]
            ]
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
