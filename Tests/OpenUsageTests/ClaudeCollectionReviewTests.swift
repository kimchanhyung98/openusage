import XCTest
@testable import OpenUsage

final class ClaudeCollectionReviewTests: XCTestCase {
    private let timestamp = "2026-10-30T12:00:00Z"

    func testNullableToolPayloadDoesNotInvalidateUsage() throws {
        let line = ClaudeLogFixture.usageLine(timestamp: timestamp, input: 10, output: 5, costUSD: 0.25)
        let expected = ClaudeLogUsageScanner.parseFile(Data(line.utf8))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        var message = try XCTUnwrap(object["message"] as? [String: Any])
        let fields = ["id", "model", "cwd", "version", "sessionId", "requestId", "costUSD", "speed",
                      "isApiErrorMessage", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let payload = Dictionary(uniqueKeysWithValues: fields.map { ($0, NSNull()) })
        message["content"] = [
            ["type": "tool_use", "id": "tool-1", "name": "lookup", "input": ["nested": [payload]]],
            ["type": "tool_result", "tool_use_id": "tool-1", "content": payload],
        ]
        object["message"] = message
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertFalse(ClaudeLogUsageScanner.hasUnsupportedNullField(data))
        XCTAssertEqual(ClaudeLogUsageScanner.parseFile(data), expected)
        XCTAssertEqual(ClaudeLogUsageScanner.parseLine(data), expected.first)
    }

    func testNullAtSchemaLocationStillRejectsTheUsageRow() throws {
        let line = ClaudeLogFixture.usageLine(timestamp: timestamp, input: 10, output: 5, costUSD: 0.25)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        for field in ["id", "model"] {
            var object = original
            var message = try XCTUnwrap(object["message"] as? [String: Any])
            message[field] = NSNull()
            object["message"] = message
            let data = try JSONSerialization.data(withJSONObject: object)

            XCTAssertTrue(ClaudeLogUsageScanner.hasUnsupportedNullField(data))
            XCTAssertTrue(ClaudeLogUsageScanner.parseFile(data).isEmpty)
            XCTAssertNil(ClaudeLogUsageScanner.parseLine(data))
        }
    }

    func testCompactionTokensAreAdditionalUnattributedUsageAndDeduplicate() throws {
        let line = #"{"timestamp":"2026-10-30T12:00:00Z","requestId":"request","costUSD":0.25,"message":{"id":"parent","model":"fixture-parent","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"message","input_tokens":10,"output_tokens":5},{"type":"compaction","input_tokens":100,"output_tokens":20},{"type":"advisor_message","model":"fixture-advisor","input_tokens":3,"output_tokens":2}]}}}"#
        let entries = ClaudeLogUsageScanner.parseFile(Data(line.utf8))
        let deduped = ClaudeLogUsageScanner.dedup(entries + entries)
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["fixture-advisor": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20, cacheWritePerMillion: 12.5, cacheReadPerMillion: 1
            )]),
            secondary: PricingCatalog(entries: [:])
        )
        let scan = ClaudeLogUsageScanner.aggregate(entries: deduped, since: .distantPast, pricing: pricing)

        XCTAssertEqual(deduped.count, 3)
        XCTAssertEqual(deduped.map(\.messageID), ["parent", "parent:compaction:0", "parent:advisor:0"])
        XCTAssertNil(deduped[1].model)
        XCTAssertNil(deduped[1].costUSD)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 140)
        XCTAssertNil(scan.series.daily.first?.costUSD)
        XCTAssertEqual(scan.unsupportedPricingRows, 1)
        XCTAssertNotNil(scan.pricingWarning)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        let models = scan.modelUsage?.daily.first?.models ?? []
        XCTAssertEqual(models.first { $0.model == ModelUsageEntry.unattributedModelName },
                       ModelUsageEntry(model: ModelUsageEntry.unattributedModelName, totalTokens: 120, costUSD: nil))
        XCTAssertEqual(models.first { $0.model == "fixture-parent" }?.costUSD, 0.25)
        XCTAssertEqual(try XCTUnwrap(models.first { $0.model == "fixture-advisor" }?.costUSD), 0.00007, accuracy: 1e-12)
    }

    func testSeparateCompactionsKeepIndependentTokensAndInvalidNumbersRemainRejected() {
        let line = #"{"timestamp":"2026-10-30T12:00:00Z","costUSD":0.25,"message":{"id":"parent","model":"fixture-parent","usage":{"input_tokens":10,"output_tokens":5,"iterations":[{"type":"compaction","input_tokens":100,"output_tokens":20},{"type":"compaction","input_tokens":30,"output_tokens":4},{"type":"compaction","input_tokens":-1,"output_tokens":2}]}}}"#
        let entries = ClaudeLogUsageScanner.parseFile(Data(line.utf8))
        let scan = ClaudeLogUsageScanner.aggregate(
            entries: ClaudeLogUsageScanner.dedup(entries + entries), since: .distantPast, pricing: .empty
        )

        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 169)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
        XCTAssertNotNil(scan.numericWarning)
        XCTAssertNil(scan.series.daily.first?.costUSD)
    }

    func testCommaInConfigDirRemainsOnePathAcrossRepeatedScans() async throws {
        let now = Date()
        let fixture = try makeHome(files: ["p/session.jsonl": usageLine(now: now)])
        let directory = fixture.appendingPathComponent("team,inc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.appendingPathComponent("projects"),
                                         to: directory.appendingPathComponent("projects"))
        let scanner = ClaudeLogFixture.scanner(home: directory)

        for _ in 0..<2 {
            let result = await scanner.scan(now: now, pricing: .empty)
            let scan = try XCTUnwrap(result)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
            XCTAssertEqual(scan.series.daily.first?.costUSD, 0.25)
            XCTAssertEqual(scan.readFailureCount, 0)
        }
    }

    func testUnreadableNativeFileKeepsHistoryUnavailableAndRecovers() async throws {
        let now = Date()
        let directory = try makeHome(files: ["p/session.jsonl": usageLine(now: now)])
        let file = directory.appendingPathComponent("projects/p/session.jsonl")
        try blockReads(file)
        let scanner = ClaudeLogFixture.scanner(home: directory)

        let failedResult = await scanner.scan(now: now, pricing: .empty)
        let failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(failed.readFailureCount, 1)
        XCTAssertNotNil(failed.readWarning)
        XCTAssertNil(failed.usageHistory)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let recoveredResult = await scanner.scan(now: now, pricing: .empty)
        let recovered = try XCTUnwrap(recoveredResult)
        XCTAssertEqual(recovered.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(recovered.readFailureCount, 0)
        XCTAssertNotNil(recovered.usageHistory)
    }

    func testPartialNativeReadFailureKeepsReadableUsageWithWarning() async throws {
        let now = Date()
        let directory = try makeHome(files: [
            "p/good.jsonl": usageLine(now: now),
            "p/unreadable.jsonl": usageLine(now: now, id: "unreadable"),
        ])
        try blockReads(directory.appendingPathComponent("projects/p/unreadable.jsonl"))

        let result = await ClaudeLogFixture.scanner(home: directory).scan(now: now, pricing: .empty)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(scan.readFailureCount, 1)
        XCTAssertNotNil(scan.readWarning)
        XCTAssertNotNil(scan.usageHistory)
    }

    func testUnreadableProjectsDirectoryPreservesDiscoveryFailure() async throws {
        let now = Date()
        let directory = try makeHome(files: ["p/session.jsonl": usageLine(now: now)])
        try blockReads(directory.appendingPathComponent("projects"))

        let result = await ClaudeLogFixture.scanner(home: directory).scan(now: now, pricing: .empty)
        let scan = try XCTUnwrap(result)
        XCTAssertGreaterThan(scan.readFailureCount, 0)
        XCTAssertNotNil(scan.readWarning)
        XCTAssertNil(scan.usageHistory)
    }

    func testUnreadableCoworkDirectoryKeepsNativeUsageAndWarning() async throws {
        let now = Date()
        let directory = try ClaudeLogFixture.makeUserHome(claudeFiles: ["p/session.jsonl": usageLine(now: now)])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cowork = directory.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        try FileManager.default.createDirectory(at: cowork, withIntermediateDirectories: true)
        try blockReads(cowork)

        let result = await ClaudeLogFixture.scanner(userHome: directory).scan(now: now, pricing: .empty)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertGreaterThan(scan.readFailureCount, 0)
        XCTAssertNotNil(scan.readWarning)
        XCTAssertNotNil(scan.usageHistory)
    }

    private func usageLine(now: Date, id: String = "fixture") -> String {
        ClaudeLogFixture.usageLine(timestamp: OpenUsageISO8601.string(from: now), input: 10, output: 5,
                                   costUSD: 0.25, messageID: id)
    }

    private func makeHome(files: [String: String]) throws -> URL {
        let directory = try ClaudeLogFixture.makeHome(files: files)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func blockReads(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
}
