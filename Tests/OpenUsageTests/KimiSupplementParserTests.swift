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

    func testWorkMissingUsageIsAnInvalidRecord() throws {
        for usage in ["", #","usage":false"#] {
            let json = #"{"type":"usage.record","id":"r","time":1800000000000"# + usage + "}"
            let records = try KimiSupplementParser.parse(Data(json.utf8), path: "/fixture/wire.jsonl", work: true)
            XCTAssertEqual(records.count, 1)
            XCTAssertTrue(records[0].issues.contains(.invalidMetadata))
        }
    }

    func testDuplicatePrefersValidUsageOverLargerIncompleteUsage() throws {
        let valid = try row(work: true, id: "same", input: 100)
        let invalid = Data(#"{"type":"usage.record","id":"same","time":1800000000000,"usage":{"inputOther":999,"output":10}}"#.utf8)
        for data in [valid + Data([0x0A]) + invalid, invalid + Data([0x0A]) + valid] {
            let records = try KimiSupplementParser.parse(data, path: "/fixture/wire.jsonl", work: true)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.totalTokens, 130)
            XCTAssertTrue(records.first?.issues.isEmpty == true)
        }
    }

    func testLegacyDuplicatePrefersValidOverLargerMissingTimestamp() throws {
        let valid = try row(work: false, id: "same", input: 100)
        let invalid = Data(#"{"message":{"type":"StatusUpdate","payload":{"message_id":"same","token_usage":{"input_other":999,"output":10}}}}"#.utf8)
        for data in [valid + Data([0x0A]) + invalid, invalid + Data([0x0A]) + valid] {
            let records = try KimiSupplementParser.parse(data, path: "/fixture/wire.jsonl", work: false)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.totalTokens, 130)
            XCTAssertTrue(records.first?.issues.isEmpty == true)
        }
    }

    func testExplicitNonKimiRoutingIsPreservedButNotAttributed() throws {
        let request = #"{"type":"llm.request","agentId":"main","kind":"loop","modelAlias":"kimi-code/custom","model":"gpt-5"}"#
        let usage = #"{"type":"usage.record","id":"r","agentId":"main","usageScope":"turn","model":"kimi-code/custom","time":1800000000000,"usage":{"inputOther":100,"output":10,"inputCacheRead":20}}"#
        let records = try KimiSupplementParser.parse(Data((request + "\n" + usage).utf8), path: "/fixture/wire.jsonl", work: true)
        XCTAssertEqual(records.first?.totalTokens, 130)
        XCTAssertNil(records.first?.providerID)
        XCTAssertTrue(records.first?.issues.isEmpty == true)
    }

    func testIncompleteExplicitRequestIsUnattributedButAbsentRequestRetainsWorkFallback() throws {
        let usage = #"{"type":"usage.record","id":"r","agentId":"main","usageScope":"turn","model":"kimi-code/k3","time":1800000000000,"usage":{"inputOther":100,"output":10,"inputCacheRead":20}}"#
        let models: [Any?] = [nil, false, ""]
        for model in models {
            var request: [String: Any] = [
                "type": "llm.request", "agentId": "main", "kind": "loop", "modelAlias": "kimi-code/k3"
            ]
            if let model { request["model"] = model }
            let data = try JSONSerialization.data(withJSONObject: request) + Data([0x0A]) + Data(usage.utf8)
            let records = try KimiSupplementParser.parse(data, path: "/fixture/wire.jsonl", work: true)
            XCTAssertEqual(records.first?.totalTokens, 130)
            XCTAssertNil(records.first?.providerID)
        }
        let legacy = try KimiSupplementParser.parse(Data(usage.utf8), path: "/fixture/wire.jsonl", work: true)
        XCTAssertEqual(legacy.first?.providerID, "kimi")
        XCTAssertEqual(legacy.first?.totalTokens, 130)
    }

    func testLinkedWorkRequestRequiresMatchingAliasesAndRecoversAfterDamagedRouting() throws {
        let alias = "kimi-code/k3"
        for (requestAlias, usageModel) in [(nil, alias), (alias, nil), (alias, "kimi-code/other"), (alias, alias)] as [(String?, String?)] {
            var request: [String: Any] = ["type": "llm.request", "agentId": "main", "kind": "loop", "model": "k3"]
            var usage: [String: Any] = [
                "type": "usage.record", "id": "r", "agentId": "main", "usageScope": "turn", "time": 1_800_000_000_000,
                "usage": ["inputOther": 100, "output": 10, "inputCacheRead": 20]
            ]
            request["modelAlias"] = requestAlias
            usage["model"] = usageModel
            let requestData = try JSONSerialization.data(withJSONObject: request) + Data([0x0A])
            let usageData = try JSONSerialization.data(withJSONObject: usage)
            for data in [requestData + usageData, requestData + Data("not-json\n".utf8) + requestData + usageData] {
                let records = try KimiSupplementParser.parse(data, path: "/fixture/wire.jsonl", work: true)
                let measured = try XCTUnwrap(records.first { $0.kind == "usage" })
                XCTAssertEqual(measured.totalTokens, 130)
                XCTAssertEqual(measured.providerID, requestAlias == alias && usageModel == alias ? "kimi" : nil)
            }
        }
    }

    func testUnlinkedUsageWithExplicitNonKimiRequestStaysUnattributed() throws {
        let usage = #"{"type":"usage.record","time":1800000000000,"usage":{"inputOther":100,"output":10,"inputCacheRead":20}}"#
        let nonKimi = #"{"type":"llm.request","agentId":"main","modelAlias":"external","model":"gpt-5"}"#
        let kimi = #"{"type":"llm.request","agentId":"main","modelAlias":"kimi-code/k3","model":"k3"}"#
        for (prefix, expected) in [(nonKimi + "\n", Optional<String>.none), ("", "kimi"), (kimi + "\n", "kimi")] {
            let records = try KimiSupplementParser.parse(Data((prefix + usage).utf8), path: "/fixture/wire.jsonl", work: true)
            XCTAssertEqual(records.first?.providerID, expected)
            XCTAssertEqual(records.first?.totalTokens, 130)
        }
    }

    func testWorkMissingRequiredTokenFieldsRemainsIncomplete() throws {
        for missing in ["inputOther", "output", "inputCacheRead"] {
            var usage = ["inputOther": 100, "output": 10, "inputCacheRead": 20]
            usage.removeValue(forKey: missing)
            let data = try JSONSerialization.data(withJSONObject: ["type": "usage.record", "time": 1_800_000_000_000, "usage": usage] as [String: Any])
            let records = try KimiSupplementParser.parse(data, path: "/fixture/wire.jsonl", work: true)
            XCTAssertTrue(records[0].issues.contains(.invalidMetadata))
        }
    }

    func testUnsupportedWorkMetadataRejectsWholeFile() throws {
        let metadata = Data(#"{"type":"metadata","protocol_version":"9.0"}"#.utf8) + Data([0x0A])
        let data = metadata + (try row(work: true, id: "r", input: 100))
        XCTAssertThrowsError(try KimiSupplementParser.parse(data, path: "/fixture/wire.jsonl", work: true)) { error in
            guard let kimiError = error as? KimiHistoryError, case .unsupportedFormat = kimiError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testWorkCollectorOnlyReadsExactAgentWirePaths() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent("Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions")
        let data = try row(work: true, id: "r", input: 100)
        for path in ["workspace/session/agents/main/wire.jsonl", "workspace/session/agents/main/backup/wire.jsonl", "workspace/session/backup/agents/main/wire.jsonl"] {
            try UsageRecordFixture.write(data, to: root.appendingPathComponent(path))
        }
        let collector = UsageSourceCollectors.kimiWork(home: home, scanner: IncrementalJSONLScanner())
        let collection = await collector.collect(since: .distantPast)
        XCTAssertEqual(collection?.records.count, 1)
        XCTAssertEqual(collection?.records.first?.totalTokens, 130)
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
