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

    func testQwenNoThoughtTotalValidationPreservesFallbackAndTotalOnly() throws {
        func parse(_ usage: String) throws -> UsageRecord {
            let json = #"{"type":"assistant","uuid":"r","sessionId":"s","timestamp":"2026-11-01T00:00:01Z","model":"qwen","usageMetadata":\#(usage)}"#
            return try XCTUnwrap(QwenSessionParser.parse(Data(json.utf8), path: "/session.jsonl",
                                                        resources: URL(fileURLWithPath: "/unused")).first)
        }
        let matching = try parse(#"{"promptTokenCount":100,"candidatesTokenCount":30,"totalTokenCount":130}"#)
        XCTAssertFalse(matching.issues.contains(.invalidMetadata))
        XCTAssertEqual(matching.totalTokens, 130)
        let mismatched = try parse(#"{"promptTokenCount":100,"candidatesTokenCount":30,"totalTokenCount":300}"#)
        XCTAssertTrue(mismatched.issues.contains(.invalidMetadata))
        for usage in [#"{"promptTokenCount":100,"candidatesTokenCount":30,"totalTokenCount":0}"#,
                      #"{"promptTokenCount":100,"candidatesTokenCount":30}"#] {
            let fallback = try parse(usage)
            XCTAssertFalse(fallback.issues.contains(.invalidMetadata))
            XCTAssertEqual(fallback.totalTokens, 130)
        }
        let totalOnly = try parse(#"{"totalTokenCount":300,"thoughtsTokenCount":0}"#)
        XCTAssertFalse(totalOnly.issues.contains(.invalidMetadata))
        XCTAssertEqual(totalOnly.totalTokens, 300)
    }

    func testQwenRegularParserPropagatesCancellationBeforeDecoding() async {
        let task = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try QwenSessionParser.parse(Data("not-json\n".utf8), path: "/session.jsonl",
                                                resources: URL(fileURLWithPath: "/unused"))
                return false
            } catch is CancellationError { return true } catch { return false }
        }
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
    }

    func testQwenIncompleteFinalRowPreservesCompleteRowsAndValidUnterminatedRow() throws {
        let row = #"{"type":"assistant","uuid":"r","sessionId":"s","timestamp":"2026-11-01T00:00:01Z","model":"qwen","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"totalTokenCount":130}}"#
        func parse(_ text: String) throws -> [UsageRecord] {
            try QwenSessionParser.parse(Data(text.utf8), path: "/projects/a/chats/s.jsonl",
                                        resources: URL(fileURLWithPath: "/unused"))
        }
        XCTAssertEqual(try parse(row + "\n" + #"{"type":"assistant"#).map(\.totalTokens), [130])
        XCTAssertEqual(try parse(row).map(\.totalTokens), [130])
        XCTAssertThrowsError(try parse(row + "\nnot-json\n"))
        XCTAssertThrowsError(try parse("not-json"))
    }

    func testQwenSeparatesWorkspaceLineagesButStillDeduplicatesForks() throws {
        let original = #"{"type":"assistant","uuid":"r1","sessionId":"main","timestamp":"2026-11-01T00:00:01Z","model":"qwen","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"totalTokenCount":130}}"#
        let fork = original.replacingOccurrences(of: #""sessionId":"main""#,
            with: #""sessionId":"fork","forkedFrom":{"sessionId":"main","messageUuid":"r1"}"#)
        func parse(_ text: String, path: String) throws -> [UsageRecord] {
            try QwenSessionParser.parse(Data(text.utf8), path: path, resources: URL(fileURLWithPath: "/unused"))
        }
        let records = try parse(original, path: "/home1/projects/a/chats/main.jsonl")
            + parse(fork, path: "/home1/projects/a/chats/fork.jsonl")
            + parse(original, path: "/home1/projects/b/chats/main.jsonl")
            + parse(fork, path: "/home1/projects/b/chats/fork.jsonl")
            + parse(original, path: "/home2/projects/a/chats/main.jsonl")
        let deduped = UsageRecordDeduplicator.records(records)
        XCTAssertEqual(deduped.count, 3)
        XCTAssertEqual(deduped.map(\.totalTokens).reduce(0, +), 390)
    }

    func testQwenReasoningSeparateFromCandidateTokens() throws {
        let row = #"{"type":"assistant","uuid":"r","sessionId":"s","timestamp":"2026-11-01T00:00:01Z","model":"qwen","usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":30,"thoughtsTokenCount":10,"totalTokenCount":140}}"#
        let result = try QwenSessionParser.parse(Data(row.utf8), path: "/projects/a/chats/s.jsonl",
                                                 resources: URL(fileURLWithPath: "/unused"))
        XCTAssertEqual(result.first?.totalTokens, 140)
        XCTAssertEqual(result.first?.tokens?.output, 40)
        XCTAssertEqual(result.first?.reasoningTokens, 10)
        XCTAssertTrue(result.first?.issues.isEmpty == true)
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

    func testDeepSeekSettlementsReplaceAttemptsButRetriesAndCompactionRemain() async throws {
        let rows = """
        {"type":"session","id":"s","version":4,"isSeeded":true}
        {"type":"assistant/message","seq":0,"time":1793494800000,"data":{"usage":{"inputTokens":999}}}
        {"type":"session/end-seed","seq":1,"data":{"inherited":true}}
        {"type":"request/header","seq":1,"data":{"header":{"config":{"provider":"anthropic","model":"requested-model"}}}}
        {"type":"assistant/attempt","seq":2,"time":1793494800000,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":100,"outputTokens":20}}}]}}
        {"type":"assistant/message","seq":3,"time":1793494801000,"data":{"turn":1,"step":1,"message":{"id":"r1","source":{"replayState":{"response":{"responseModel":"resolved-model"}}}},"usage":{"inputTokens":80,"outputTokens":10,"reasoningTokens":2}}}
        {"type":"llm/retry-started","seq":4,"data":{"turn":1,"step":1}}
        {"type":"assistant/attempt","seq":5,"time":1793494802000,"data":{"turn":1,"step":1,"stream":[{"type":"chunk","chunk":{"type":"usage","usage":{"inputTokens":5,"outputTokens":5}}}]}}
        {"type":"compaction/summary","seq":6,"time":1793494803000,"data":{"compactionId":"c1","provider":"anthropic","model":"summary-model","usage":{"inputTokens":20,"outputTokens":2}}}
        """
        let result = try await UsageRecordFixture.collect(["session.v4.jsonl": rows + "\n"], sourceID: "dsh", parse: DeepSeekSessionParser.parse)
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 122)
        let settled = try XCTUnwrap(result.records.first { $0.id == "r1" })
        XCTAssertEqual(settled.model, "requested-model")
        XCTAssertEqual(settled.responseModel, "resolved-model")
        XCTAssertEqual(settled.tokens?.output, 10)
        XCTAssertEqual(settled.reasoningTokens, 2)
        XCTAssertEqual(settled.providerID, "anthropic")
    }

}
