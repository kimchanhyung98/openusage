import XCTest
@testable import Egasu

enum UsageRecordFixture {
    static func piRecords(_ data: Data) throws -> [UsageRecord] {
        try PiSessionParser.parse(data, path: "/fixture/session.jsonl", sourceID: "pi")
    }

    static func piRecord(_ data: Data) throws -> UsageRecord? { try piRecords(data).first }

    static func record(
        timestamp: Date, providerID: String, model: String, cost: Double?, tokens: TokenBreakdown, total: Int
    ) -> UsageRecord {
        UsageRecord(sourceID: "pi", formatID: "pi-session", kind: "message", timestamp: timestamp,
                    providerID: providerID, model: model.nilIfEmpty, tokens: tokens, totalTokens: total,
                    recordedCostUSD: cost, zeroCostIsUnknown: true)
    }

    static func history(
        records: [UsageRecord], providerID: String, since: Date, pricing: ModelPricing,
        costEstimator: UsageHistoryBuilder.CostEstimator? = nil
    ) -> LogUsageScan {
        UsageHistoryBuilder.scan(.init(records: records), providerID: providerID, since: since,
                                 pricing: pricing, costEstimator: costEstimator) ?? DailyUsageAccumulator().build()
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("UsageCollectionTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func write(_ text: String, to url: URL) throws { try write(Data(text.utf8), to: url) }

    static func collect(
        _ files: [String: String], sourceID: String, parse: @escaping UsageFileCollector.Parser
    ) async throws -> UsageCollection {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, text) in files { try write(text, to: root.appendingPathComponent(name)) }
        let collector = UsageFileCollector(sourceID: sourceID, roots: [root], scanner: IncrementalJSONLScanner(),
                                           includeFile: { _ in true }, parse: parse)
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.readFailureCount, 0)
        return result
    }
}
