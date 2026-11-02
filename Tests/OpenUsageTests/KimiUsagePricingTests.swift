import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class KimiUsagePricingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pricing = ModelPricing(
        supplement: PricingSupplement(pricing: [
            "kimi-k3": ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1),
            "kimi-k3.1-pro": ModelRates(inputPerMillion: 3, outputPerMillion: 4, cacheWritePerMillion: 3, cacheReadPerMillion: 0.3),
            "kimi-k3.1-pro-highspeed": ModelRates(inputPerMillion: 5, outputPerMillion: 6, cacheWritePerMillion: 5, cacheReadPerMillion: 0.5)
        ]),
        primary: PricingCatalog(), secondary: PricingCatalog()
    )

    func testAllFourExplicitCodeModelsReachTheSharedPriceAndDashboard() throws {
        for (model, expected) in [("k3", 1.4), ("k3-256k", 1.4), ("k3.1-pro", 4.0), ("k3.1-pro-highspeed", 6.6)] {
            let parsed = try parse([request(model: model), usage(model: model)])
            let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)
            let total = total(result, period: .today)

            XCTAssertEqual(total.totalTokens, 3_100_000, model)
            XCTAssertEqual(total.totalUSD, expected, accuracy: 0.000_001, model)
            XCTAssertEqual(total.projection(for: .costPerMtok).centerValue, expected / 3.1, accuracy: 0.000_001, model)
            XCTAssertTrue(total.isEstimated)
            XCTAssertTrue(result.warnings.isEmpty)
        }
    }

    func testMissingOffAndUnknownThinkingKeepEveryTokenWithoutCost() throws {
        for effort in [nil, "off", "none", "disabled", "unrecognized"] as [String?] {
            let parsed = try parse([request(effort: effort), usage()])
            let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)
            XCTAssertEqual(total(result, period: .today).totalTokens, 3_100_000)
            XCTAssertTrue(total(result, period: .today).projection(for: .cost).isEmpty)
            XCTAssertEqual(result.warnings.count, 1)
        }
        for effort in ["on", "low", "high", "max"] {
            let parsed = try parse([request(effort: effort), usage()])
            let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)
            XCTAssertEqual(total(result, period: .today).totalUSD, 1.4, accuracy: 0.000_001)
        }
    }

    func testMovingAliasesAndAPIModelNamesDoNotBypassCodeRouting() throws {
        for model in ["kimi-for-coding", "kimi-for-coding-highspeed", "kimi-k3", "kimi-k3.1-pro", "K3"] {
            let parsed = try parse([request(model: model), usage(model: model)])
            let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)
            XCTAssertEqual(total(result, period: .today).totalTokens, 3_100_000, model)
            XCTAssertTrue(total(result, period: .today).projection(for: .cost).isEmpty, model)
        }
    }

    func testProtocolAndCacheWriteBoundariesPreserveTokensWithoutAssumingTTL() throws {
        let cases: [(String, Int, Int, Bool)] = [
            ("anthropic", 1_000_000, 0, true),
            ("anthropic", 1_000_000, 1, false),
            ("openai", 1_000_000, 0, false),
            ("openai_responses", 1_000_000, 0, false),
            ("openai", 0, 0, true),
            ("openai_responses", 0, 0, true),
            ("openai", 0, 1, false),
            ("unknown", 0, 0, false)
        ]
        for (protocolName, input, writes, priced) in cases {
            let parsed = try parse([
                request(protocolName: protocolName), usage(input: input, writes: writes)
            ])
            let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)
            let total = total(result, period: .today)
            XCTAssertEqual(total.totalTokens, Double(input + writes + 2_100_000))
            XCTAssertEqual(!total.projection(for: .cost).isEmpty, priced, protocolName)
            XCTAssertEqual(result.warnings.isEmpty, priced, protocolName)
        }
    }

    func testUnpricedYesterdayDoesNotHideTodayCostButDisablesWholeThirtyDayCost() throws {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let parsed = try parse([
            request(), usage(),
            request(model: "kimi-for-coding"), usage(model: "kimi-for-coding", date: yesterday)
        ])
        let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)

        XCTAssertEqual(total(result, period: .today).totalUSD, 1.4, accuracy: 0.000_001)
        XCTAssertEqual(total(result, period: .yesterday).totalTokens, 3_100_000)
        XCTAssertTrue(total(result, period: .yesterday).projection(for: .costPerMtok).isEmpty)
        XCTAssertEqual(total(result, period: .last30).totalTokens, 6_200_000)
        XCTAssertTrue(total(result, period: .last30).projection(for: .cost).isEmpty)
        XCTAssertTrue(total(result, period: .last30).projection(for: .costPerMtok).isEmpty)
    }

    func testOneUnpricedRequestDisablesSameDayCostAndKeepsFullDenominator() throws {
        let parsed = try parse([request(), usage(), request(effort: "off"), usage()])
        let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)

        XCTAssertEqual(total(result, period: .today).totalTokens, 6_200_000)
        XCTAssertTrue(total(result, period: .today).projection(for: .cost).isEmpty)
        XCTAssertTrue(total(result, period: .last30).projection(for: .cost).isEmpty)
    }

    func testInterleavedCompactionCannotPriceAThinkingDisabledTurn() throws {
        var compaction = request(effort: "high")
        compaction["kind"] = "compaction"
        var compactionUsage = usage()
        compactionUsage["usageScope"] = "session"
        let parsed = try parse([request(effort: "off"), compaction, usage(), compactionUsage])
        let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)

        XCTAssertEqual(total(result, period: .today).totalTokens, 6_200_000)
        XCTAssertTrue(total(result, period: .today).projection(for: .cost).isEmpty)
        XCTAssertTrue(total(result, period: .last30).projection(for: .costPerMtok).isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testInterleavedCompactionKeepsEachRequestsModelPriceAndTokens() throws {
        var compaction = request(model: "k3.1-pro")
        compaction["kind"] = "compaction"
        var compactionUsage = usage(model: "k3.1-pro")
        compactionUsage["usageScope"] = "session"
        let parsed = try parse([request(), compaction, usage(), compactionUsage])
        let result = KimiUsageScanner.aggregate([parsed], now: now, pricing: pricing)

        XCTAssertEqual(total(result, period: .today).totalTokens, 6_200_000)
        XCTAssertEqual(total(result, period: .today).totalUSD, 5.4, accuracy: 0.000_001)
        XCTAssertEqual(result.invalidRows, 0)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMissingOrUnknownRequestScopeKeepsTokensWithoutAssumingRequestAssociation() throws {
        for field in ["kind", "usageScope"] {
            for value in [nil, "unknown"] as [String?] {
                var request = request()
                var usage = usage()
                if field == "kind" { request[field] = value } else { usage[field] = value }
                let result = KimiUsageScanner.aggregate([try parse([request, usage])], now: now, pricing: pricing)

                XCTAssertEqual(total(result, period: .today).totalTokens, 3_100_000)
                XCTAssertTrue(total(result, period: .today).projection(for: .cost).isEmpty, field)
                XCTAssertEqual(result.warnings.count, 1, field)
            }
        }
    }

    func testMissingPriceKeepsTokensAndZeroUsageNeedsNoWarning() throws {
        let parsed = try parse([request(), usage()])
        let missing = KimiUsageScanner.aggregate([parsed], now: now, pricing: .empty)
        XCTAssertEqual(total(missing, period: .today).totalTokens, 3_100_000)
        XCTAssertTrue(total(missing, period: .today).projection(for: .cost).isEmpty)
        XCTAssertEqual(missing.warnings.count, 1)

        let zero = try parse([request(effort: nil), usage(input: 0, output: 0, reads: 0, writes: 0)])
        let idle = KimiUsageScanner.aggregate([zero], now: now, pricing: .empty)
        XCTAssertTrue(idle.totalSpendLines(now: now).isEmpty)
        XCTAssertTrue(idle.warnings.isEmpty)
    }

    func testBundledPricingContainsEachExplicitCanonicalModel() {
        for model in ["kimi-k3", "kimi-k3.1-pro", "kimi-k3.1-pro-highspeed"] {
            XCTAssertNotNil(TestPricing.bundled.supplement.pricing[model], model)
        }
    }

    func testSyntheticCacheReadRateCannotPriceMeasuredCachedTokens() throws {
        let synthetic = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "kimi-k3": ModelRates(
                    inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1,
                    cacheReadPerMillion: 0.1, cacheReadIsExplicit: false
                )
            ]), primary: PricingCatalog(), secondary: PricingCatalog()
        )
        let cached = KimiUsageScanner.aggregate([try parse([request(), usage()])], now: now, pricing: synthetic)
        XCTAssertEqual(total(cached, period: .today).totalTokens, 3_100_000)
        XCTAssertTrue(total(cached, period: .today).projection(for: .cost).isEmpty)
        XCTAssertFalse(cached.warnings.isEmpty)

        let uncached = KimiUsageScanner.aggregate(
            [try parse([request(), usage(reads: 0)])], now: now, pricing: synthetic
        )
        XCTAssertEqual(total(uncached, period: .today).totalUSD, 1.2, accuracy: 0.000_001)
    }

    private func total(_ result: KimiUsageScanner.Result, period: TotalSpendPeriod) -> TotalSpend {
        let provider = KimiProvider().provider
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: [], totalSpendLines: result.totalSpendLines(now: now), refreshedAt: now
        )
        return TotalSpendAggregator.total(for: period, providers: [provider], snapshots: ["kimi": snapshot])
    }

    private func request(
        model: String = "k3", protocolName: String = "anthropic", effort: String? = "high"
    ) -> [String: Any] {
        var row: [String: Any] = [
            "type": "llm.request", "agentId": "main", "kind": "loop", "provider": protocolName,
            "model": model, "modelAlias": "kimi-code/\(model)"
        ]
        row["thinkingEffort"] = effort
        return row
    }

    private func usage(
        model: String = "k3", date: Date? = nil,
        input: Int = 1_000_000, output: Int = 100_000, reads: Int = 2_000_000, writes: Int = 0
    ) -> [String: Any] {
        ["type": "usage.record", "agentId": "main", "usageScope": "turn", "model": "kimi-code/\(model)",
         "time": Int((date ?? now).timeIntervalSince1970 * 1_000),
         "usage": ["inputOther": input, "output": output, "inputCacheRead": reads, "inputCacheCreation": writes]]
    }

    private func parse(_ rows: [[String: Any]]) throws -> KimiUsageScanner.ParsedFile {
        var data = Data()
        for row in [["type": "metadata", "protocol_version": "1.5"]] + rows {
            data.append(try JSONSerialization.data(withJSONObject: row))
            data.append(0x0A)
        }
        return try KimiUsageScanner.parse(data)
    }
}
