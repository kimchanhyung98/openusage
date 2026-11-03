import XCTest
@testable import OpenUsage

final class PiUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }

    /// carried-$0 fall-through 검증용 fixture pricing (composer input $10/M)
    private let pricing = ModelPricing(
        supplement: PricingSupplement(),
        primary: PricingCatalog(entries: [
            "composer-2.5": ModelRates(
                inputPerMillion: 10, outputPerMillion: 20,
                cacheWritePerMillion: 10, cacheReadPerMillion: 1
            )
        ]),
        secondary: PricingCatalog(entries: [:])
    )

    private func line(
        id: String = "m1", ts: String = "2026-07-12T10:00:00.000Z", provider: String = "anthropic",
        model: String = "claude-opus-4-8", input: Int = 100, output: Int = 50,
        cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int = 0, total: Int = 150,
        cost: String? = "0.5", costObject: String? = nil
    ) -> Data {
        let costJSON = costObject.map { ",\"cost\":\($0)" } ?? cost.map { ",\"cost\":{\"total\":\($0)}" } ?? ""
        let json = """
        {"type":"message","id":"\(id)","timestamp":"\(ts)","message":{"role":"assistant","provider":"\(provider)","model":"\(model)","usage":{"input":\(input),"output":\(output),"cacheRead":\(cacheRead),"cacheWrite":\(cacheWrite),"cacheWrite1h":\(cacheWrite1h),"totalTokens":\(total)\(costJSON)}}}
        """
        return Data(json.utf8)
    }

    // MARK: - Parsing

    func testParsesMappedAnthropicLine() {
        let entry = PiUsageScanner.parseLine(line())
        XCTAssertEqual(entry?.cardID, "claude")
        XCTAssertEqual(entry?.model, "claude-opus-4-8")
        XCTAssertEqual(entry?.carriedCost, 0.5)
        XCTAssertEqual(entry?.reportedTotalTokens, 150)
        XCTAssertEqual(entry?.tokens.input, 100)
        XCTAssertEqual(entry?.tokens.output, 50)
    }

    func testSplitsCacheWriteBucketsBy1hPortion() {
        let entry = PiUsageScanner.parseLine(line(cacheWrite: 1000, cacheWrite1h: 400))
        XCTAssertEqual(entry?.tokens.cacheWrite1h, 400)
        XCTAssertEqual(entry?.tokens.cacheWrite5m, 600)
    }

    func testMapsCodexAndSkipsUnmappedAndNonAssistant() {
        XCTAssertEqual(PiUsageScanner.parseLine(line(provider: "openai-codex"))?.cardID, "codex")
        XCTAssertNil(PiUsageScanner.parseLine(line(provider: "nvidia-nim")))
        let userLine = Data(#"{"type":"message","timestamp":"2026-07-12T10:00:00.000Z","message":{"role":"user","provider":"anthropic","usage":{}}}"#.utf8)
        XCTAssertNil(PiUsageScanner.parseLine(userLine))
    }

    func testExplicitUsageRemainsWhenCompactionModelIsMissing() {
        let entries = parseRecords([
            #"{"type":"message","id":"m1","parentId":null,"timestamp":"2026-07-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":800,"output":200,"totalTokens":1000,"cost":{"total":1}}}}"#,
            #"{"type":"compaction","id":"c1","parentId":"m1","timestamp":"2026-07-12T10:01:00Z","usage":{"input":180,"output":20,"totalTokens":200,"cost":{"total":0.2}}}"#,
            #"{"type":"usage","kind":"cache_warm","id":"u1","parentId":"c1","timestamp":"2026-07-12T10:02:00Z","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":80,"output":20,"totalTokens":100,"cost":{"total":0.1}}}"#
        ])
        XCTAssertEqual(entries.count, 3)
        let scan = PiUsageScanner.aggregate(
            entries: PiUsageScanner.dedup(entries + entries), cardID: "claude", since: .distantPast, pricing: .empty
        )
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1100)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 1.1, accuracy: 1e-9)
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
    }

    func testCompactionAfterTreeNavigationDoesNotBorrowEitherBranchesModel() {
        let entries = parseRecords([
            #"{"type":"model_change","id":"a","parentId":null,"provider":"anthropic","modelId":"claude-opus-4-8"}"#,
            #"{"type":"model_change","id":"b","parentId":"a","provider":"openai-codex","modelId":"gpt-5"}"#,
            #"{"type":"message","id":"user-a","parentId":"a","message":{"role":"user","content":"fixture"}}"#,
            #"{"type":"compaction","id":"ca","parentId":"user-a","timestamp":"2026-07-12T10:00:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#,
            #"{"type":"compaction","id":"cb","parentId":"b","timestamp":"2026-07-12T11:00:00Z","usage":{"input":200,"totalTokens":200,"cost":{"total":0.3}}}"#
        ])
        XCTAssertEqual(entries.count, 2)
        for cardID in ["claude", "codex"] {
            let scan = PiUsageScanner.aggregate(entries: entries, cardID: cardID, since: .distantPast, pricing: .empty)
            XCTAssertTrue(scan.series.daily.isEmpty)
            XCTAssertEqual(scan.rejectedMetadataRows, 2)
            XCTAssertNotNil(scan.metadataWarning)
        }
    }

    func testCompactionWithoutParentContextStillWarns() {
        let entries = parseRecords([
            #"{"type":"model_change","id":"a","parentId":null,"provider":"anthropic","modelId":"claude-opus-4-8"}"#,
            #"{"type":"compaction","id":"c","parentId":"missing","timestamp":"2026-07-12T10:00:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#
        ])
        XCTAssertEqual(entries.count, 1)
        for cardID in ["claude", "codex"] {
            let scan = PiUsageScanner.aggregate(entries: entries, cardID: cardID, since: .distantPast, pricing: .empty)
            XCTAssertEqual(scan.rejectedMetadataRows, 1)
            XCTAssertNil(scan.usageHistory)
        }
    }

    func testCompactionCannotUsePreviousModelAfterAnUnrecordedResumeOverride() {
        let entries = parseRecords([
            #"{"type":"model_change","id":"a","parentId":null,"provider":"anthropic","modelId":"claude-opus-4-8"}"#,
            #"{"type":"message","id":"answer","parentId":"a","timestamp":"2026-07-12T10:00:00Z","message":{"role":"assistant","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":50,"totalTokens":50,"cost":{"total":0.1}}}}"#,
            #"{"type":"compaction","id":"c","parentId":"answer","timestamp":"2026-07-12T10:01:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#
        ])
        let claude = PiUsageScanner.aggregate(entries: entries, cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(claude.series.daily.first?.totalTokens, 50)
        XCTAssertEqual(claude.series.daily.first?.costUSD, 0.1)
        XCTAssertEqual(claude.rejectedMetadataRows, 1)
        let codex = PiUsageScanner.aggregate(entries: entries, cardID: "codex", since: .distantPast, pricing: .empty)
        XCTAssertTrue(codex.series.daily.isEmpty)
        XCTAssertEqual(codex.rejectedMetadataRows, 1)
    }

    func testCopiedCompactionCannotLoseItsWarningWhenOtherBranchesAreOmitted() {
        let compact = #"{"type":"compaction","id":"c","parentId":"a","timestamp":"2026-07-12T10:00:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#
        let selection = #"{"type":"model_change","id":"a","parentId":null,"provider":"anthropic","modelId":"claude-opus-4-8"}"#
        let original = parseRecords([
            selection,
            #"{"type":"model_change","id":"b","parentId":"a","provider":"openai-codex","modelId":"gpt-5"}"#,
            compact
        ])
        let copy = parseRecords([selection, compact])
        for entries in [original + copy, copy + original] {
            let deduplicated = PiUsageScanner.dedup(entries)
            XCTAssertEqual(deduplicated.count, 1)
            for cardID in ["claude", "codex"] {
                let scan = PiUsageScanner.aggregate(
                    entries: deduplicated, cardID: cardID, since: .distantPast, pricing: .empty
                )
                XCTAssertEqual(scan.rejectedMetadataRows, 1)
                XCTAssertTrue(scan.series.daily.isEmpty)
            }
        }
    }

    func testHookAndRoutedCompactionsWarnInsteadOfBorrowingSelectedModel() {
        let entries = parseRecords([
            #"{"type":"model_change","id":"a","parentId":null,"provider":"anthropic","modelId":"claude-opus-4-8"}"#,
            #"{"type":"compaction","id":"hook","parentId":"a","fromHook":true,"timestamp":"2026-07-12T10:00:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#,
            #"{"type":"message","id":"routed","parentId":"a","timestamp":"2026-07-12T10:01:00Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5","usage":{"input":50,"totalTokens":50,"cost":{"total":0.1}}}}"#,
            #"{"type":"compaction","id":"routed-compact","parentId":"routed","timestamp":"2026-07-12T10:02:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#
        ])
        let scan = PiUsageScanner.aggregate(entries: entries, cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.rejectedMetadataRows, 2)
        XCTAssertNotNil(scan.metadataWarning)
        XCTAssertNil(scan.usageHistory)
        let merged = DailyUsageAccumulator.merged([scan])
        XCTAssertEqual(merged?.rejectedMetadataRows, 2)
        XCTAssertNotNil(merged?.metadataWarning)
        let codex = PiUsageScanner.aggregate(entries: entries, cardID: "codex", since: .distantPast, pricing: .empty)
        XCTAssertEqual(codex.series.daily.first?.totalTokens, 50)
        XCTAssertEqual(codex.series.daily.first?.costUSD, 0.1)
    }

    func testVirtualModelMessageCannotAttributeCompaction() {
        let entries = parseRecords([
            #"{"type":"message","id":"virtual","parentId":null,"message":{"role":"assistant","provider":"anthropic","model":"virtual-model","api":"pi-virtual"}}"#,
            #"{"type":"compaction","id":"c","parentId":"virtual","timestamp":"2026-07-12T10:02:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":0.2}}}"#
        ])
        let scan = PiUsageScanner.aggregate(entries: entries, cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
        XCTAssertNil(scan.usageHistory)
    }

    func testIndependentRecordsKeepNumericValidationAndPricingFallback() throws {
        let entries = parseRecords([
            #"{"type":"model_change","id":"a","parentId":null,"provider":"anthropic","modelId":"claude-opus-4-8"}"#,
            #"{"type":"usage","id":"bad-usage","timestamp":"2026-07-12T10:00:00Z","provider":"anthropic","model":"claude-opus-4-8","usage":{"input":-1,"totalTokens":100}}"#,
            #"{"type":"compaction","id":"bad-compaction","parentId":"a","timestamp":"2026-07-12T10:01:00Z","usage":{"input":100,"totalTokens":100,"cost":{"total":true}}}"#
        ])
        let scan = PiUsageScanner.aggregate(entries: entries, cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.rejectedNumericRows, 1)
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
        XCTAssertNil(scan.usageHistory)
        let usage = Data(#"{"type":"usage","timestamp":"2026-07-12T10:00:00Z","provider":"cursor","model":"composer-2.5","usage":{"input":100,"output":50,"totalTokens":150,"cost":{"total":0}}}"#.utf8)
        let entry = try XCTUnwrap(PiUsageScanner.parseLine(usage))
        let priced = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(priced.series.daily.first?.costUSD), 0.002, accuracy: 1e-9)
    }

    private func parseRecords(_ lines: [String]) -> [PiUsageScanner.Entry] {
        PiUsageScanner.parseFile(Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    // MARK: - Aggregation

    func testCarriedCostUsedWhenPresent() {
        let scan = PiUsageScanner.aggregate(
            entries: [PiUsageScanner.parseLine(line(cost: "0.5"))!],
            cardID: "claude", since: .distantPast, pricing: .empty
        )
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 150)
    }

    func testZeroCarriedCostFallsThroughToPricing() {
        // log가 $0이면 engine이 산정 — input 100 @ $10/M + output 50 @ $20/M = $0.002
        let entry = PiUsageScanner.parseLine(line(provider: "cursor", model: "composer-2.5", cost: "0"))!
        let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: pricing)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.002, accuracy: 0.00001)
    }

    func testInvalidExplicitCarriedCostRejectsRowInsteadOfEstimating() throws {
        for cost in ["-0.5", "true", "false", #""NaN""#, #""Infinity""#, #""invalid""#, "null"] {
            let entry = try XCTUnwrap(PiUsageScanner.parseLine(line(provider: "cursor", model: "composer-2.5", cost: cost)))
            let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: pricing)
            XCTAssertTrue(entry.invalidNumericValues, cost)
            XCTAssertEqual(scan.rejectedNumericRows, 1, cost)
            XCTAssertNil(scan.usageHistory, cost)
            XCTAssertNotNil(scan.numericWarning, cost)
        }
    }

    func testMissingAndNumericStringCarriedCostKeepExistingBehavior() throws {
        for (cost, expected) in [(nil as String?, 0.002), (#""0""#, 0.002), (#""0.5""#, 0.5)] {
            let entry = try XCTUnwrap(PiUsageScanner.parseLine(line(provider: "cursor", model: "composer-2.5", cost: cost)))
            let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: pricing)
            XCTAssertFalse(entry.invalidNumericValues)
            XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expected, accuracy: 1e-9)
            XCTAssertNil(scan.numericWarning)
        }
    }

    func testMalformedCostObjectWarnsButMissingTotalStillUsesPricing() throws {
        for (costObject, rejected) in [("null", true), ("true", true), ("0", true), ("[]", true),
                                       (#""invalid""#, true), ("{}", false), (#"{"input":0.5}"#, false)] {
            let entry = try XCTUnwrap(PiUsageScanner.parseLine(line(provider: "cursor", model: "composer-2.5", costObject: costObject)))
            let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: pricing)
            XCTAssertEqual(entry.invalidNumericValues, rejected, costObject)
            XCTAssertEqual(scan.rejectedNumericRows, rejected ? 1 : 0, costObject)
            if rejected {
                XCTAssertNil(scan.usageHistory, costObject)
                XCTAssertNotNil(scan.numericWarning, costObject)
            } else {
                XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.002, accuracy: 1e-9)
                XCTAssertNil(scan.numericWarning)
            }
        }
    }

    func testUnpriceableZeroCostBecomesUnknownModel() {
        let entry = PiUsageScanner.parseLine(line(provider: "cursor", model: "mystery-model", cost: "0"))!
        let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "cursor", since: .distantPast, pricing: .empty)
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unknownModelsByDay["2026-07-12"], ["mystery-model"])
    }

    func testDedupDropsRepeatedIDs() {
        let entries = [PiUsageScanner.parseLine(line(id: "dup"))!, PiUsageScanner.parseLine(line(id: "dup"))!]
        let scan = PiUsageScanner.aggregate(entries: PiUsageScanner.dedup(entries), cardID: "claude", since: .distantPast, pricing: .empty)
        XCTAssertEqual(scan.series.daily.first?.costUSD ?? 0, 0.5, accuracy: 0.0001)
    }

    func testFiltersToRequestedCard() {
        let scan = PiUsageScanner.aggregate(
            entries: [PiUsageScanner.parseLine(line(provider: "openai-codex"))!],
            cardID: "claude", since: .distantPast, pricing: .empty
        )
        XCTAssertTrue(scan.series.daily.isEmpty)
    }

    // MARK: - Mapping and merge

    func testProviderMapping() {
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "claude-agent-sdk"), "claude")
        XCTAssertEqual(PiProviderMapping.cardID(forPiProvider: "zhipu"), "zai")
        XCTAssertNil(PiProviderMapping.cardID(forPiProvider: "nvidia-nim"))
    }

    func testMergedSumsNativeAndPiOnSameDay() {
        let native = DailyUsageAccumulator.merged([
            PiUsageScanner.aggregate(entries: [PiUsageScanner.parseLine(line(id: "n", cost: "1.0"))!], cardID: "claude", since: .distantPast, pricing: .empty)
        ])
        let pi = PiUsageScanner.aggregate(entries: [PiUsageScanner.parseLine(line(id: "p", cost: "0.5"))!], cardID: "claude", since: .distantPast, pricing: .empty)
        let merged = DailyUsageAccumulator.merged([native, pi])
        XCTAssertEqual(merged?.series.daily.first?.costUSD ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(merged?.series.daily.first?.totalTokens, 300)
    }

    func testMergedReturnsNilWhenAllNil() {
        XCTAssertNil(DailyUsageAccumulator.merged([nil, nil]))
    }
}
