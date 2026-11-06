import XCTest
@testable import OpenUsage

final class GeminiCollectionReviewTests: XCTestCase {
    func testMalformedJSONLRowsPreserveValidUsageAndMetadataWarning() throws {
        let text = """
        {"sessionId":"s"}
        {"id":"a","type":"gemini","timestamp":"2026-11-01T01:00:00Z","tokens":{"input":100,"output":20,"total":120}}
        {interrupted write
        {"id":"b","type":"gemini","timestamp":"2026-11-01T01:01:00Z","tokens":{"input":50,"output":10,"total":60}}
        {"id":
        """
        let records = try GeminiSessionParser.parse(Data(text.utf8), path: "/fixture/session.jsonl")
        XCTAssertEqual(records.filter { $0.issues.isEmpty }.count, 2)
        XCTAssertEqual(records.filter { $0.issues.contains(.invalidMetadata) }.count, 2)
        XCTAssertEqual(records.reduce(0) { $0 + $1.totalTokens }, 180)
        XCTAssertThrowsError(try GeminiSessionParser.parse(Data(text.utf8), path: "/fixture/session.json"))
    }

    func testCancellationInsideSnapshotAndJSONLStopsWithoutInvalidLine() async {
        let first = #"{"id":"first","type":"gemini","timestamp":"2026-11-01T01:00:00Z","tokens":{"total":10}}"#
        let second = #"{"id":"second","type":"gemini","timestamp":"2026-11-01T01:01:00Z","tokens":{"total":20}}"#
        let cases = [
            ("/fixture/session.json", "{\"sessionId\":\"s\",\"messages\":[\(first),\(second)]}"),
            ("/fixture/session.jsonl", "{\"sessionId\":\"s\"}\n\(first)\n\(second)")
        ]
        for (path, text) in cases {
            let cancelled = await Task { () -> Bool in
                do {
                    _ = try GeminiSessionParser.parse(Data(text.utf8), path: path, onObject: { object in
                        if object["id"] as? String == "second" {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
                    return false
                } catch is CancellationError {
                    return true
                } catch {
                    return false
                }
            }.value
            XCTAssertTrue(cancelled, path)
        }
    }

    func testRepeatedMessageIDOnlyReplacesRevisionWithinSameSession() throws {
        let text = """
        {"sessionId":"first"}
        {"id":"same","type":"gemini","timestamp":"2026-11-01T01:00:00Z","tokens":{"total":10}}
        {"sessionId":"second"}
        {"id":"same","type":"gemini","timestamp":"2026-11-01T01:01:00Z","tokens":{"total":20}}
        {"sessionId":"first"}
        {"id":"same","type":"gemini","timestamp":"2026-11-01T01:02:00Z","tokens":{"total":30}}
        """
        let records = try GeminiSessionParser.parse(Data(text.utf8), path: "/fixture/session.jsonl")
        XCTAssertEqual(records.map(\.sessionID), ["first", "second"])
        XCTAssertEqual(records.map(\.totalTokens), [30, 20])
    }

    func testCacheIsAlwaysSubsetOfPromptRegardlessOfReportedTotal() throws {
        let text = #"{"id":"a","type":"gemini","timestamp":"2026-11-01T01:00:00Z","tokens":{"input":100,"output":30,"cached":20,"thoughts":10,"tool":5,"total":140}}"#
        let record = try XCTUnwrap(GeminiSessionParser.parse(Data(text.utf8), path: "/fixture/session.jsonl").first)
        XCTAssertEqual(record.tokens?.input, 85)
        XCTAssertEqual(record.tokens?.cacheRead, 20)
        XCTAssertEqual(record.tokens?.output, 40)
        XCTAssertEqual(record.totalTokens, 140)
        XCTAssertTrue(record.issues.isEmpty)
        let invalid = text.replacingOccurrences(of: #""input":100"#, with: #""input":10"#)
        XCTAssertTrue(try GeminiSessionParser.parse(Data(invalid.utf8), path: "/fixture/session.jsonl").first?.issues.contains(.invalidNumbers) == true)
    }
}
