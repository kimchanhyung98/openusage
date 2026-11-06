import XCTest
@testable import OpenUsage

final class UsageHistoryBuilderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testMalformedSharedRootRecordRemainsIncompleteForMappedProviders() throws {
        let records = try PiSessionParser.parse(Data("broken JSON\n".utf8), path: "/fixture", sourceID: "pi-omp")
        XCTAssertEqual(records.count, 1)
        for provider in ["claude", "codex"] {
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                UsageCollection(records: records, sources: [.init(sourceID: "pi", completedStores: 1)]),
                providerID: provider, since: .distantPast, pricing: .empty
            ))
            XCTAssertEqual(scan.rejectedMetadataRows, 1)
            XCTAssertNil(scan.usageHistory)
        }
    }

    func testDeletingOneProvidersSessionClearsItsHistoryAfterSuccessfulCollection() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let claude = directory.appendingPathComponent("claude.jsonl")
        let codex = directory.appendingPathComponent("codex.jsonl")
        let line = #"{"type":"message","id":"m1","timestamp":"2026-11-01T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"fixture","usage":{"input":100,"output":20,"cost":{"total":0.5,"totalFromProvider":true}}}}"#
        try UsageRecordFixture.write(line, to: claude)
        try UsageRecordFixture.write(line.replacingOccurrences(of: "anthropic", with: "openai-codex"), to: codex)
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [directory], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" },
            parse: { try PiSessionParser.parse($0, path: $1, sourceID: "pi") }
        )
        let firstCollection = await collector.collect(since: .distantPast)
        let first = try XCTUnwrap(firstCollection)
        XCTAssertEqual(UsageHistoryBuilder.scan(first, providerID: "claude", since: .distantPast,
                                               pricing: .empty)?.series.daily.first?.totalTokens, 120)
        try FileManager.default.removeItem(at: claude)
        let nextCollection = await collector.collect(since: .distantPast)
        let next = try XCTUnwrap(nextCollection)
        let cleared = try XCTUnwrap(UsageHistoryBuilder.scan(next, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertTrue(cleared.series.daily.isEmpty)
        XCTAssertNotNil(cleared.usageHistory)
        XCTAssertEqual(UsageHistoryBuilder.scan(next, providerID: "codex", since: .distantPast,
                                               pricing: .empty)?.series.daily.first?.totalTokens, 120)
    }

    func testAbsentFailedAndUnrelatedSourcesDoNotBecomeCompletedEmptyHistory() throws {
        for source in [
            UsageSourceState(sourceID: "pi"),
            UsageSourceState(sourceID: "other", providerID: "codex", completedStores: 1),
            UsageSourceState(sourceID: "other", scope: .accountWide, completedStores: 1)
        ] {
            XCTAssertNil(UsageHistoryBuilder.scan(UsageCollection(records: [], sources: [source]),
                                                 providerID: "claude", since: .distantPast, pricing: .empty))
        }
        let failed = try XCTUnwrap(UsageHistoryBuilder.scan(
            UsageCollection(records: [], sources: [.init(sourceID: "pi", failedStores: 1)]),
            providerID: "claude", since: .distantPast, pricing: .empty
        ))
        XCTAssertEqual(failed.readFailureCount, 1)
        XCTAssertNil(failed.usageHistory)
    }

    func testEmptyUnsupportedRecordKeepsAValidEmptyHistory() throws {
        let flagged = record(tokens: 0, cost: nil, unsupported: true)
        let estimated = record(tokens: 0, cost: nil)
        for value in [flagged, estimated] {
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                UsageCollection(records: [value]), providerID: "claude", since: .distantPast,
                pricing: .empty, costEstimator: { _, _ in .unsupportedUsage }
            ))
            XCTAssertEqual(scan.unsupportedPricingRows, 0)
            XCTAssertTrue(scan.series.daily.isEmpty)
            XCTAssertNotNil(scan.usageHistory)
            XCTAssertNil(scan.pricingWarning)
        }
    }

    func testReportedCostDoesNotBecomeUnsupportedBecauseOfPricingMetadata() throws {
        for tokens in [0, 100] {
            for cost in [0.0, 2.0] {
                let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                    UsageCollection(records: [record(tokens: tokens, cost: cost, unsupported: true)]),
                    providerID: "claude", since: .distantPast, pricing: .empty
                ))
                XCTAssertEqual(scan.unsupportedPricingRows, 0)
                XCTAssertEqual(scan.series.daily.first?.totalTokens, tokens)
                XCTAssertEqual(scan.series.daily.first?.costUSD, cost)
                XCTAssertNotNil(scan.usageHistory)
                XCTAssertNil(scan.pricingWarning)
            }
        }
    }

    func testUnsupportedPositiveTokensStayVisibleWithoutCost() throws {
        for unsupported in [true, false] {
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                UsageCollection(records: [record(tokens: 100, cost: nil, unsupported: unsupported)]),
                providerID: "claude", since: .distantPast, pricing: .empty,
                costEstimator: { _, _ in .unsupportedUsage }
            ))
            XCTAssertEqual(scan.unsupportedPricingRows, 1)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
            XCTAssertNil(scan.series.daily.first?.costUSD)
            XCTAssertNotNil(scan.usageHistory)
            XCTAssertNotNil(scan.pricingWarning)
        }
    }

    private func record(tokens: Int, cost: Double?, unsupported: Bool = false) -> UsageRecord {
        UsageRecord(sourceID: "pi", formatID: "pi-session", kind: "message", timestamp: date,
                    providerID: "claude", model: "fixture", totalTokens: tokens, recordedCostUSD: cost,
                    issues: unsupported ? [.unsupportedPricing] : [])
    }
}
