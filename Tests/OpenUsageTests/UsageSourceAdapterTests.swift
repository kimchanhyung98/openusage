import XCTest
@testable import OpenUsage

final class UsageSourceAdapterTests: XCTestCase {
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
