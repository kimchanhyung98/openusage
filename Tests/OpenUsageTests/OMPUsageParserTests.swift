import XCTest
@testable import OpenUsage

final class OMPUsageParserTests: XCTestCase {
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: ["fixture-model": ModelRates(
            inputPerMillion: 10, outputPerMillion: 20,
            cacheWritePerMillion: 10, cacheReadPerMillion: 1
        )]),
        secondary: PricingCatalog(entries: [:])
    )

    private func data(
        usage: String, type: String = "model_usage", messageTimestamp: String? = nil,
        envelope: String = "2026-11-02T00:00:10Z"
    ) -> Data {
        let timestamp = messageTimestamp.map { ",\"timestamp\":\($0)" } ?? ""
        let payload = "\"provider\":\"anthropic\",\"model\":\"fixture-model\",\"usage\":\(usage)"
        let body = type == "message"
            ? "\"message\":{\"role\":\"assistant\",\(payload)\(timestamp)}"
            : payload
        return Data("{\"type\":\"\(type)\",\"id\":\"m1\",\"timestamp\":\"\(envelope)\",\(body)}".utf8)
    }

    private func record(_ data: Data) throws -> UsageRecord {
        try XCTUnwrap(PiSessionParser.parse(data, path: "/fixture/session.jsonl", sourceID: "omp").first)
    }

    func testOfficialReasoningAndTTLFieldsApplyToMessagesAndModelUsage() throws {
        let usage = #"{"input":100,"output":50,"cacheRead":20,"cacheWrite":100,"cttl":{"ephemeral5m":25,"ephemeral1h":75},"reasoningTokens":5,"totalTokens":270,"cost":{"total":0}}"#
        for type in ["message", "model_usage"] {
            let parsed = try record(data(usage: usage, type: type))
            XCTAssertTrue(parsed.issues.isEmpty)
            XCTAssertEqual(parsed.reasoningTokens, 5)
            XCTAssertEqual(parsed.tokens?.output, 50)
            XCTAssertEqual(parsed.tokens?.cacheWrite5m, 25)
            XCTAssertEqual(parsed.tokens?.cacheWrite1h, 75)
            XCTAssertEqual(parsed.totalTokens, 270)
            let history = UsageRecordFixture.history(records: [parsed], providerID: "claude", since: .distantPast, pricing: pricing)
            XCTAssertEqual(try XCTUnwrap(history.series.daily.first?.costUSD), 0.00377, accuracy: 1e-10)
        }
    }

    func testInvalidReasoningNumbersAreDiagnosed() throws {
        for value in ["-1", "0.5", "true", "9223372036854775808", "51"] {
            let parsed = try record(data(usage: "{\"input\":100,\"output\":50,\"reasoningTokens\":\(value)}"))
            XCTAssertTrue(parsed.issues.contains(.invalidNumbers), value)
            let history = UsageRecordFixture.history(records: [parsed], providerID: "claude", since: .distantPast, pricing: pricing)
            XCTAssertNotNil(history.numericWarning)
        }
    }

    func testIncompleteTTLRetainsKnownTokensWithoutInventingPrices() throws {
        for ttl in [
            "true", "null", #"{"ephemeral5m":25,"ephemeral1h":-1}"#,
            #"{"ephemeral5m":25,"ephemeral1h":0.5}"#, #"{"ephemeral5m":true,"ephemeral1h":75}"#,
            #"{"ephemeral5m":25,"ephemeral1h":9223372036854775808}"#,
            #"{"ephemeral5m":25,"ephemeral1h":74}"#,
        ] {
            let parsed = try record(data(usage: "{\"input\":100,\"output\":50,\"cacheWrite\":100,\"cttl\":\(ttl)}"))
            XCTAssertTrue(parsed.issues.contains(.unsupportedPricing), ttl)
            XCTAssertEqual(parsed.totalTokens, 250)
            XCTAssertNil(parsed.tokens)
            let history = UsageRecordFixture.history(records: [parsed], providerID: "claude", since: .distantPast, pricing: pricing)
            XCTAssertEqual(history.series.daily.first?.totalTokens, 250)
            XCTAssertNil(history.series.daily.first?.costUSD)
            XCTAssertNotNil(history.pricingWarning)
        }
        let recorded = try record(data(usage: #"{"input":100,"output":50,"cacheWrite":100,"cttl":true,"cost":{"total":0.25}}"#))
        let history = UsageRecordFixture.history(records: [recorded], providerID: "claude", since: .distantPast, pricing: pricing)
        XCTAssertTrue(recorded.issues.contains(.unsupportedPricing))
        XCTAssertEqual(history.series.daily.first?.costUSD, 0.25)
        XCTAssertEqual(history.unsupportedPricingRows, 0)
        XCTAssertNil(history.pricingWarning)
        let missingTotal = try record(data(usage: #"{"input":100,"output":50,"cttl":{"ephemeral1h":75}}"#))
        XCTAssertTrue(missingTotal.issues.contains(.invalidNumbers))
    }

    func testOrchestrationContributesToBucketsAndExplicitOrDerivedTotal() throws {
        for total in ["", ",\"totalTokens\":215"] {
            let parsed = try record(data(usage: "{\"input\":100,\"output\":50,\"cacheRead\":20,\"orchestration\":{\"input\":30,\"output\":5,\"cacheRead\":10},\"reasoningTokens\":5\(total)}"))
            XCTAssertTrue(parsed.issues.isEmpty)
            XCTAssertEqual(parsed.tokens?.input, 130)
            XCTAssertEqual(parsed.tokens?.output, 55)
            XCTAssertEqual(parsed.tokens?.cacheRead, 30)
            XCTAssertEqual(parsed.totalTokens, 215)
            XCTAssertEqual(parsed.reasoningTokens, 5)
            let history = UsageRecordFixture.history(records: [parsed], providerID: "claude", since: .distantPast, pricing: pricing)
            XCTAssertEqual(try XCTUnwrap(history.series.daily.first?.costUSD), 0.00243, accuracy: 1e-10)
        }
    }

    func testOrchestrationIsIncludedInLongContextThreshold() throws {
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["fixture-model": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20, cacheWritePerMillion: 10, cacheReadPerMillion: 1,
                inputAbove200kPerMillion: 20, outputAbove200kPerMillion: 40,
                longContextThresholdTokens: 200
            )]), secondary: PricingCatalog(entries: [:])
        )
        let parsed = try record(data(usage: #"{"input":180,"output":50,"orchestration":{"input":30,"output":5}}"#))
        XCTAssertEqual(parsed.tokens?.promptTokens, 210)
        let history = UsageRecordFixture.history(records: [parsed], providerID: "claude", since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(history.series.daily.first?.costUSD), 0.0064, accuracy: 1e-10)
    }

    func testInvalidOrchestrationNeedsAuthoritativeTotalToRetainTokens() throws {
        for value in ["true", "null", #"{"input":-1}"#, #"{"output":0.5}"#, #"{"cacheRead":true}"#, #"{"input":9223372036854775808}"#] {
            let known = try record(data(usage: "{\"input\":100,\"output\":50,\"totalTokens\":215,\"orchestration\":\(value)}"))
            XCTAssertTrue(known.issues.contains(.unsupportedPricing), value)
            XCTAssertNil(known.tokens)
            let history = UsageRecordFixture.history(records: [known], providerID: "claude", since: .distantPast, pricing: pricing)
            XCTAssertEqual(history.series.daily.first?.totalTokens, 215)
            XCTAssertNil(history.series.daily.first?.costUSD)
            XCTAssertNotNil(history.pricingWarning)
            let unknown = try record(data(usage: "{\"input\":100,\"output\":50,\"orchestration\":\(value)}"))
            XCTAssertTrue(unknown.issues.contains(.invalidNumbers), value)
        }
        let overflow = try record(data(usage: "{\"input\":\(Int.max),\"orchestration\":{\"input\":1}}"))
        XCTAssertTrue(overflow.issues.contains(.invalidNumbers))
    }

    func testMessageTimestampPrecedesEnvelopeAndInvalidValuesFallback() throws {
        let envelope = "2026-11-02T00:00:10Z"
        let requested = OpenUsageISO8601.date(from: "2026-11-01T23:59:50Z")!
        let recorded = OpenUsageISO8601.date(from: envelope)!
        let usage = #"{"input":100,"output":50}"#
        let message = try record(data(usage: usage, type: "message", messageTimestamp: String(requested.timeIntervalSince1970 * 1000)))
        XCTAssertEqual(message.timestamp, requested)
        XCTAssertFalse(message.overlaps(since: recorded.addingTimeInterval(-10)))
        for timestamp in [nil, "0", "-1", "true", "null", "\"invalid\"", "\"1793577590000\""] as [String?] {
            let parsed = try record(data(usage: usage, type: "message", messageTimestamp: timestamp))
            XCTAssertEqual(parsed.timestamp, recorded)
        }
        XCTAssertEqual(try record(data(usage: usage)).timestamp, recorded)
    }

    func testOMPDoesNotTreatPiOnlyCostFlagAsReportedBilling() throws {
        let parsed = try record(data(usage: #"{"input":100,"output":50,"cost":{"total":0,"totalFromProvider":true}}"#))
        XCTAssertEqual(parsed.costOrigin, .estimated)
        XCTAssertTrue(parsed.zeroCostIsUnknown)
        let history = UsageRecordFixture.history(records: [parsed], providerID: "claude", since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(history.series.daily.first?.costUSD), 0.002, accuracy: 1e-10)
    }

    func testSchemaChangeReparsesPriorOMPTokenCache() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        try UsageRecordFixture.write(data(usage: #"{"input":100,"output":50,"orchestration":{"input":30}}"#), to: file)
        let cache = root.appendingPathComponent("cache")
        let oldPersistence = JSONLScanCachePersistence(namespace: "omp", schemaVersion: 11, directory: cache, writeDebounce: .milliseconds(1))
        let old = UsageFileCollector(
            sourceID: "omp", roots: [file], scanner: IncrementalJSONLScanner(persistence: oldPersistence),
            includeFile: { _ in true }, parse: { _, _ in
                [UsageRecord(sourceID: "omp", formatID: "pi-session", kind: "model_usage", totalTokens: 150)]
            }
        )
        let oldResult = await old.collect(since: .distantPast)
        XCTAssertEqual(oldResult?.records.first?.totalTokens, 150)
        await old.flushCache()
        let currentPersistence = JSONLScanCachePersistence(
            namespace: "omp", schemaVersion: PiUsageScanner.cacheSchemaVersion,
            directory: cache, writeDebounce: .milliseconds(1)
        )
        let current = UsageFileCollector(
            sourceID: "omp", roots: [file], scanner: IncrementalJSONLScanner(persistence: currentPersistence),
            includeFile: { _ in true }, parse: { try PiSessionParser.parse($0, path: $1, sourceID: "omp") }
        )
        let currentResult = await current.collect(since: .distantPast)
        XCTAssertEqual(currentResult?.records.first?.totalTokens, 180)
        XCTAssertEqual(currentResult?.records.first?.tokens?.input, 130)
    }
}
