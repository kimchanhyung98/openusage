import XCTest
@testable import OpenUsage

final class ClaudeLogParsingTests: XCTestCase {
    private var directory: URL!
    private var previousSink: LogFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        previousSink = AppLog.sink
        AppLog.sink = LogFile(directory: directory, fileName: "fixture.log")
    }

    override func tearDownWithError() throws {
        AppLog.sink = previousSink
        try? FileManager.default.removeItem(at: directory)
    }

    func testWhitespacePreservesFileParsingAndDeduplication() {
        let line = ClaudeLogFixture.usageLine(timestamp: "2026-09-17T03:00:00Z", input: 17, output: 9, costUSD: 0.25)
        let compact = ClaudeLogUsageScanner.parseFile(Data(line.utf8))
        XCTAssertEqual(compact.count, 1)
        for separator in [": ", " : ", "\t:\t"] {
            let spaced = line.replacingOccurrences(of: "\":", with: "\"" + separator)
            let parsed = ClaudeLogUsageScanner.parseFile(Data(spaced.utf8))
            XCTAssertEqual(parsed, compact)
            XCTAssertEqual(ClaudeLogUsageScanner.dedup(compact + parsed), compact)
        }
    }

    func testNullChecksRejectWhitespaceVariantsWithoutRejectingQuotedContent() throws {
        let line = ClaudeLogFixture.usageLine(timestamp: "2026-09-17T03:00:00Z", input: 1, output: 2)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        object["note"] = #"example: "speed":null, "usage":{}"#
        XCTAssertEqual(ClaudeLogUsageScanner.parseFile(try JSONSerialization.data(withJSONObject: object)).count, 1)
        object["costUSD"] = NSNull()
        let null = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        for separator in [":", ": ", "\t:\t"] {
            let spaced = null.replacingOccurrences(of: "\":", with: "\"" + separator)
            XCTAssertTrue(ClaudeLogUsageScanner.parseFile(Data(spaced.utf8)).isEmpty)
        }
    }

    func testAdvisorTotalsSurviveWhitespaceAndUnsupportedRowsReportOncePerFile() throws {
        let capture = ClaudeParsingDiagnosticCapture()
        let observer = AppDiagnostics.observe { event, _ in capture.append(event) }
        defer { AppDiagnostics.removeObserver(observer) }
        let valid = #"{"timestamp":"2026-09-17T03:00:00Z","costUSD":0.25,"message":{"id":"parent","model":"fixture-parent","usage" : {"input_tokens":10,"output_tokens":5,"iterations":[{"type":"advisor_message","model":"fixture-advisor","input_tokens":3,"output_tokens":2}]}}}"#
        let invalid = ClaudeLogFixture.usageLine(timestamp: "2026-09-17T03:00:00Z", input: 1, output: 2, speed: "unknown")
        let lines = [valid, invalid, invalid, #"{"message":{"content":"usage"}}"#].joined(separator: "\n")
        let entries = ClaudeLogUsageScanner.parseFile(Data(lines.utf8))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?.costUSD, 0.25)
        XCTAssertEqual(entries.last?.tokens.totalTokens, 5)
        XCTAssertEqual(entries.last?.messageID, "parent:advisor:0")
        XCTAssertEqual(capture.events, [DiagnosticEvent(.historyScan, result: .degraded, category: .decoding, providerID: "claude")])
    }

    func testUnpricedUsagePreservesKnownTotalsAndEmitsOnlyFixedDiagnostic() throws {
        let capture = ClaudeParsingDiagnosticCapture()
        let observer = AppDiagnostics.observe { event, _ in capture.append(event) }
        defer { AppDiagnostics.removeObserver(observer) }
        let lines = [
            ClaudeLogFixture.usageLine(timestamp: "2026-09-17T03:00:00Z", input: 10, output: 5, costUSD: 0.25),
            ClaudeLogFixture.usageLine(timestamp: "2026-09-17T03:00:00Z", model: "PRIVATE_MODEL", input: 100, output: 20, messageID: "unknown"),
        ]
        let entries = ClaudeLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
        let scan = ClaudeLogUsageScanner.aggregate(entries: entries, since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 15)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.25)
        XCTAssertEqual(capture.events, [DiagnosticEvent(.historyScan, result: .degraded, category: .other, providerID: "claude")])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(capture.events), as: UTF8.self).contains("PRIVATE_MODEL"))
    }

    func testNewCacheVersionReparsesAnUnchangedPreviouslySkippedFile() async throws {
        let line = ClaudeLogFixture.usageLine(timestamp: "2026-09-17T03:00:00Z", input: 10, output: 5, costUSD: 0.25)
            .replacingOccurrences(of: "\":", with: "\" : ")
        let home = try ClaudeLogFixture.makeHome(files: ["project/usage.jsonl": line])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("projects"))
        var persistence = JSONLScanCachePersistence(namespace: "claude", schemaVersion: 3,
            directory: home.appendingPathComponent("cache"), writeDebounce: .milliseconds(1))
        let old = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(persistence: persistence)
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "fixture", parse: { _ in [] })
        await old.flushPendingWrites()
        persistence.schemaVersion = ClaudeLogUsageScanner.cacheSchemaVersion
        let updated = IncrementalJSONLScanner<ClaudeLogUsageScanner.Entry>(persistence: persistence)
        let entries = await updated.items(from: files, since: .distantPast, cacheIdentity: "fixture", parse: ClaudeLogUsageScanner.parseFile)
        XCTAssertEqual(entries?.first?.tokens.totalTokens, 15)
        await updated.flushPendingWrites()
    }
}

private final class ClaudeParsingDiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [DiagnosticEvent] = []
    var events: [DiagnosticEvent] { lock.withLock { values } }
    func append(_ event: DiagnosticEvent) { lock.withLock { values.append(event) } }
}
