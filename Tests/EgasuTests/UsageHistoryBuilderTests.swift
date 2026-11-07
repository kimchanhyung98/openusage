import XCTest
@testable import Egasu

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

    func testDeletingLastSessionProducesCompletedEmptyHistory() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = directory.appendingPathComponent("last.jsonl")
        let line = #"{"type":"message","id":"m1","timestamp":"2026-11-01T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"fixture","usage":{"input":100,"output":20,"cost":{"total":0.5,"totalFromProvider":true}}}}"#
        try UsageRecordFixture.write(line, to: session)
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [directory], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" },
            parse: { try PiSessionParser.parse($0, path: $1, sourceID: "pi") }
        )
        let firstCollection = await collector.collect(since: .distantPast)
        let first = try XCTUnwrap(firstCollection)
        XCTAssertEqual(first.sources.first?.completedStores, 1)
        XCTAssertNotNil(UsageHistoryBuilder.scan(first, providerID: "claude", since: .distantPast, pricing: .empty)?.usageHistory)
        try FileManager.default.removeItem(at: session)
        let emptyCollection = await collector.collect(since: .distantPast)
        let empty = try XCTUnwrap(emptyCollection)
        XCTAssertTrue(empty.records.isEmpty)
        XCTAssertEqual(empty.sources.first?.completedStores, 1)
        XCTAssertEqual(empty.sources.first?.failedStores, 0)
        let cleared = try XCTUnwrap(UsageHistoryBuilder.scan(empty, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertTrue(cleared.series.daily.isEmpty)
        XCTAssertNotNil(cleared.usageHistory)
    }

    func testMissingAndFailedFileRootsStayIncomplete() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = directory.appendingPathComponent("session.jsonl")
        let missing = UsageFileCollector(
            sourceID: "pi", roots: [session], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" }, parse: { _, _ in [] }
        )
        let absentCollection = await missing.collect(since: .distantPast)
        let absent = try XCTUnwrap(absentCollection)
        XCTAssertEqual(absent.sources.first?.completedStores, 0)
        XCTAssertEqual(absent.sources.first?.failedStores, 0)
        XCTAssertNil(UsageHistoryBuilder.scan(absent, providerID: "claude", since: .distantPast, pricing: .empty))

        try UsageRecordFixture.write("{}", to: session)
        let failed = UsageFileCollector(
            sourceID: "pi", roots: [session], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" },
            parse: { _, _ in throw CocoaError(.fileReadUnknown) }
        )
        let failureCollection = await failed.collect(since: .distantPast)
        let failure = try XCTUnwrap(failureCollection)
        XCTAssertEqual(failure.sources.first?.completedStores, 0)
        XCTAssertEqual(failure.sources.first?.failedStores, 1)
        XCTAssertNil(UsageHistoryBuilder.scan(failure, providerID: "claude", since: .distantPast, pricing: .empty)?.usageHistory)
    }

    func testFilesAgingOutOfTheQueryWindowProduceCompletedEmptyHistory() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = directory.appendingPathComponent("old.jsonl")
        let timestamp = date.addingTimeInterval(-60)
        let line = """
        {"type":"message","id":"one","timestamp":"\(EgasuISO8601.string(from: timestamp))","message":{"role":"assistant","provider":"anthropic","model":"fixture","usage":{"input":100,"output":20,"cost":{"total":0.5,"totalFromProvider":true}}}}
        """
        try UsageRecordFixture.write(line, to: session)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: session.path)
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [directory], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" },
            parse: { try PiSessionParser.parse($0, path: $1, sourceID: "pi") }
        )
        let initial = await collector.collect(since: .distantPast)
        XCTAssertEqual(initial?.records.first?.totalTokens, 120)
        let expired = await collector.collect(since: date)
        let collection = try XCTUnwrap(expired)
        XCTAssertTrue(collection.records.isEmpty)
        XCTAssertEqual(collection.sources.first?.completedStores, 1)
        XCTAssertEqual(collection.sources.first?.failedStores, 0)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
            collection, providerID: "claude", since: date, pricing: .empty
        ))
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertNotNil(scan.usageHistory)
        XCTAssertNil(scan.readWarning)
    }

    func testUnreadableEmptyRootIsNotCompleted() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restricted = directory.appendingPathComponent("restricted", isDirectory: true)
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: restricted.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path) }
        guard !FileManager.default.isReadableFile(atPath: restricted.path) else {
            throw XCTSkip("file system permits reading this directory")
        }
        let collector = UsageFileCollector(
            sourceID: "pi", roots: [restricted], scanner: IncrementalJSONLScanner(),
            includeFile: { $0.pathExtension == "jsonl" }, parse: { _, _ in [] }
        )
        let collection = await collector.collect(since: .distantPast)
        let failure = try XCTUnwrap(collection)
        XCTAssertEqual(failure.sources.first?.completedStores, 0)
        XCTAssertEqual(failure.sources.first?.failedStores, 1)
        XCTAssertNil(UsageHistoryBuilder.scan(failure, providerID: "claude", since: .distantPast, pricing: .empty)?.usageHistory)
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

    func testCoordinatorExcludesFutureRecordsAtInclusiveQueryTime() async throws {
        let offsets: [TimeInterval] = [-1, 0, 1, 86_400]
        let records = offsets.enumerated().map { index, offset in
            UsageRecord(sourceID: "pi", formatID: "fixture", id: "request-\(index)", kind: "message",
                        timestamp: date.addingTimeInterval(offset), providerID: "claude", model: "fixture",
                        totalTokens: (index + 1) * 10, recordedCostUSD: Double(index + 1) / 10)
        }
        let coordinator = UsageCollectionCoordinator(collectors: [HistoryBuilderCollection(
            value: UsageCollection(records: records, sources: [.init(sourceID: "pi", completedStores: 1)])
        )])
        let result = await coordinator.scan(providerID: "claude", now: date, pricing: .empty)
        let scan = try XCTUnwrap(result)
        XCTAssertEqual(scan.series.daily.reduce(0) { $0 + $1.totalTokens }, 30)
        XCTAssertEqual(scan.series.daily.compactMap(\.costUSD).reduce(0, +), 0.3, accuracy: 1e-12)
        XCTAssertEqual(scan.series.daily.count, 1)
    }

    func testFutureOnlyCollectionPublishesAnAuthoritativeEmptyHistory() async throws {
        var future = record(tokens: 100, cost: 1)
        future.timestamp = date.addingTimeInterval(1)
        let coordinator = UsageCollectionCoordinator(collectors: [HistoryBuilderCollection(
            value: UsageCollection(records: [future], sources: [.init(sourceID: "pi", completedStores: 1)])
        )])
        let result = await coordinator.scan(providerID: "claude", now: date, pricing: .empty)
        let scan = try XCTUnwrap(result)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertNotNil(scan.usageHistory)
    }

    func testCurrentAggregateRemainsUsableWhenItsEndIsInTheFuture() throws {
        var aggregate = record(tokens: 100, cost: 1)
        aggregate.granularity = .aggregate
        aggregate.timestamp = date.addingTimeInterval(-1)
        aggregate.intervalEnd = date.addingTimeInterval(1)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
            UsageCollection(records: [aggregate]), providerID: "claude", since: date,
            until: date, pricing: .empty
        ))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 1)
    }

    func testOMPAnthropicPriorityUsesKnownFastRateExceptDisabledFallbackOrRecordedCost() throws {
        let rates = ModelRates(inputPerMillion: 1, outputPerMillion: 1, cacheWritePerMillion: 1,
                               cacheReadPerMillion: 0.1, fastMultiplier: 2)
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: .init(entries: ["fixture": rates]), secondary: .init())
        func parsed(disabled: Bool, cost: Double = 0) throws -> UsageRecord {
            let features = disabled ? #", "disabledFeatures": ["priority"]"# : ""
            let json = """
            {"type":"message","id":"one","timestamp":"2026-11-01T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"fixture","serviceTier":"priority"\(features),"usage":{"input":1000000,"output":0,"cost":{"total":\(cost)}}}}
            """
            return try XCTUnwrap(PiSessionParser.parse(Data(json.utf8), path: "/fixture", sourceID: "omp").first)
        }
        for (record, expected) in [(try parsed(disabled: false), 2.0), (try parsed(disabled: true), 1.0),
                                   (try parsed(disabled: false, cost: 3), 3.0)] {
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(.init(records: [record]), providerID: "claude",
                                                              since: .distantPast, pricing: pricing))
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expected, accuracy: 1e-9)
        }
    }

    func testOMPAnthropicPriorityUsesBundledFastRatesWithoutScalingFastModelsTwice() throws {
        for model in ["claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-7-fast"] {
            let usage = UsageRecord(
                sourceID: "omp", formatID: "pi-session", kind: "message", timestamp: date,
                providerID: "anthropic", model: model, serviceTier: "priority",
                tokens: TokenBreakdown(input: 1_000_000), totalTokens: 1_000_000
            )
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                UsageCollection(records: [usage]), providerID: "claude", since: .distantPast,
                pricing: TestPricing.bundled
            ))
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 30, accuracy: 1e-9, model)
        }
    }

    private func record(tokens: Int, cost: Double?, unsupported: Bool = false) -> UsageRecord {
        UsageRecord(sourceID: "pi", formatID: "pi-session", kind: "message", timestamp: date,
                    providerID: "claude", model: "fixture", totalTokens: tokens, recordedCostUSD: cost,
                    issues: unsupported ? [.unsupportedPricing] : [])
    }
}

private struct HistoryBuilderCollection: UsageCollecting {
    let value: UsageCollection
    func collect(since: Date) async -> UsageCollection? { value }
}
