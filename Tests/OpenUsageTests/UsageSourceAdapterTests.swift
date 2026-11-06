import XCTest
@testable import OpenUsage

final class UsageSourceAdapterTests: XCTestCase {
    func testGeminiJSONAndJSONLDeduplicateAndIncludeSubagent() async throws {
        let message = #"{"id":"r1","timestamp":"2026-11-01T00:00:01Z","type":"gemini","model":"gemini-2.5-pro","tokens":{"input":100,"output":30,"cached":20,"thoughts":10,"tool":0,"total":140}}"#
        let child = message.replacingOccurrences(of: "r1", with: "r2")
            .replacingOccurrences(of: "100", with: "50").replacingOccurrences(of: "140", with: "90")
        let result = try await UsageRecordFixture.collect([
            "chats/main.json": #"{"sessionId":"main","messages":["# + message + "]}",
            "chats/main.jsonl": #"{"sessionId":"main"}"# + "\n" + message + "\n" + message,
            "chats/main/child.jsonl": #"{"sessionId":"child"}"# + "\n" + child
        ], sourceID: "gemini", parse: GeminiSessionParser.parse)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 230)
        let main = try XCTUnwrap(result.records.first { $0.sessionID == "main" })
        XCTAssertEqual(main.tokens?.input, 80)
        XCTAssertEqual(main.tokens?.cacheRead, 20)
        XCTAssertEqual(main.tokens?.output, 40)
        XCTAssertEqual(main.reasoningTokens, 10)
        XCTAssertNil(main.providerID)
    }

    func testGeminiLatestMessageRevisionReplacesEarlierUsage() throws {
        let rows = """
        {"sessionId":"s"}
        {"type":"gemini","id":"r","timestamp":"2026-11-01T00:00:01Z","tokens":{"input":100,"output":20,"total":120}}
        {"type":"gemini","id":"r","timestamp":"2026-11-01T00:00:01Z","tokens":{"input":50,"output":5,"total":55}}
        """
        let result = try GeminiSessionParser.parse(Data(rows.utf8), path: "/chats/session.jsonl")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.totalTokens, 55)
    }

    func testQwenForkAndReasoningAreNotDoubleCounted() async throws {
        let original = #"{"type":"assistant","uuid":"r1","sessionId":"main","timestamp":"2026-11-01T00:00:01Z","model":"qwen3-coder-plus","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"cachedContentTokenCount":20,"thoughtsTokenCount":10,"totalTokenCount":130}}"#
        let fork = original.replacingOccurrences(of: #""sessionId":"main""#, with: #""sessionId":"fork","forkedFrom":{"sessionId":"main","messageUuid":"r1"}"#)
        let next = original.replacingOccurrences(of: "r1", with: "r2").replacingOccurrences(of: "main", with: "fork")
            .replacingOccurrences(of: "00:00:01", with: "00:00:02")
        let result = try await UsageRecordFixture.collect([
            "main.jsonl": original, "fork.jsonl": fork + "\n" + next
        ], sourceID: "qwen", parse: { try QwenSessionParser.parse($0, path: $1, resources: URL(fileURLWithPath: "/unused")) })
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 260)
        XCTAssertTrue(result.records.allSatisfy { $0.tokens?.input == 80 && $0.tokens?.output == 30 })
        XCTAssertTrue(result.records.allSatisfy { $0.providerID == nil })
    }

}
