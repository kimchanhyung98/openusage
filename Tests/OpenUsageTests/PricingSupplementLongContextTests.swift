import XCTest

@testable import OpenUsage

final class PricingSupplementLongContextTests: XCTestCase {
    func testLongContextStartsAfterThresholdAndCountsAllPromptBuckets() throws {
        let rates = try XCTUnwrap(makePricing().resolve(model: "tiered-model"))
        let atThreshold = TokenBreakdown(
            input: 40_000, cacheWrite5m: 20_000, cacheWrite1h: 10_000, cacheRead: 30_000, output: 1_000)
        var aboveThreshold = atThreshold
        aboveThreshold.input += 1

        XCTAssertEqual(rates.longContextThresholdTokens, 100_000)
        XCTAssertEqual(rates.costDollars(for: atThreshold), 0.0093, accuracy: 1e-12)
        XCTAssertEqual(rates.costDollars(for: aboveThreshold), 0.0465005, accuracy: 1e-12)
    }

    func testOutputDoesNotSelectLongContextTierAndAggregatedUsageCanOptOut() throws {
        let rates = try XCTUnwrap(makePricing().resolve(model: "tiered-model"))
        XCTAssertEqual(
            rates.costDollars(for: .init(input: 100_000, output: 200_000)), 0.11, accuracy: 1e-12)
        XCTAssertEqual(
            rates.costDollars(for: .init(input: 100_001, output: 1_000), applyLongContextRates: false),
            0.0105001, accuracy: 1e-12)
    }

    func testFastResolutionPreservesThresholdAndScalesAllLongContextRatesOnce() throws {
        let pricing = try makePricing()
        let base = try XCTUnwrap(pricing.resolve(model: "tiered-model"))
        let fast = try XCTUnwrap(pricing.resolve(model: "tiered-model-fast"))
        let tokens = TokenBreakdown(
            input: 40_001, cacheWrite5m: 20_000, cacheWrite1h: 10_000, cacheRead: 30_000,
            output: 1_000, isFast: true)

        XCTAssertEqual(fast.longContextThresholdTokens, 100_000)
        XCTAssertEqual(fast.fastMultiplier, 1)
        XCTAssertEqual(base.costDollars(for: tokens), 0.093001, accuracy: 1e-12)
        XCTAssertEqual(fast.costDollars(for: tokens), 0.093001, accuracy: 1e-12)
    }

    func testLegacyEntriesWithoutLongContextKeepBaseRatesAboveDefaultThreshold() throws {
        let pricing = try makePricing(longContextJSON: nil)
        let rates = try XCTUnwrap(pricing.resolve(model: "tiered-model"))

        XCTAssertEqual(rates.longContextThresholdTokens, 200_000)
        XCTAssertNil(rates.inputAbove200kPerMillion)
        XCTAssertNil(rates.outputAbove200kPerMillion)
        XCTAssertNil(rates.cacheWriteAbove200kPerMillion)
        XCTAssertNil(rates.cacheReadAbove200kPerMillion)
        XCTAssertEqual(rates.costDollars(for: .init(input: 300_000, output: 1_000)), 0.0305, accuracy: 1e-12)
    }

    func testMalformedLongContextObjectsAreRejected() throws {
        for json in ["null", "[]", "true", "42", "{}"] {
            XCTAssertThrowsError(try makePricing(longContextJSON: json), json)
        }
        for field in [
            "threshold_tokens", "input_per_million", "output_per_million",
            "cache_write_per_million", "cache_read_per_million",
        ] {
            var tier = validLongContext
            tier.removeValue(forKey: field)
            XCTAssertThrowsError(try makePricing(longContextJSON: jsonObject(tier)), field)
        }
    }

    func testInvalidThresholdsAndRatesAreRejected() throws {
        for threshold in [0, -1, 1.5, true, "100000", NSNull()] as [Any] {
            var tier = validLongContext
            tier["threshold_tokens"] = threshold
            XCTAssertThrowsError(try makePricing(longContextJSON: jsonObject(tier)), "\(threshold)")
        }
        for field in [
            "input_per_million", "output_per_million", "cache_write_per_million", "cache_read_per_million",
        ] {
            for rate in [-0.01, true, "0.5", NSNull()] as [Any] {
                var tier = validLongContext
                tier[field] = rate
                XCTAssertThrowsError(try makePricing(longContextJSON: jsonObject(tier)), "\(field): \(rate)")
            }
            let overflowing = try jsonObject(validLongContext).replacingOccurrences(
                of: #""\#(field)"\s*:\s*[0-9.]+"#, with: #""\#(field)":1e309"#,
                options: .regularExpression)
            XCTAssertThrowsError(try makePricing(longContextJSON: overflowing), field)
        }
    }

    func testZeroLongContextRatesAreAccepted() throws {
        var tier = validLongContext
        for field in tier.keys where field != "threshold_tokens" {
            tier[field] = 0
        }
        let rates = try XCTUnwrap(makePricing(longContextJSON: jsonObject(tier)).resolve(model: "tiered-model"))
        XCTAssertEqual(rates.costDollars(for: .init(input: 100_001, output: 1_000)), 0)
    }

    private var validLongContext: [String: Any] {
        [
            "threshold_tokens": 100_000,
            "input_per_million": 0.5,
            "output_per_million": 2.5,
            "cache_write_per_million": 0.625,
            "cache_read_per_million": 0.05,
        ]
    }

    private func jsonObject(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    private func makePricing(
        longContextJSON: String? = """
            {"threshold_tokens":100000,"input_per_million":0.5,"output_per_million":2.5,
             "cache_write_per_million":0.625,"cache_read_per_million":0.05}
            """
    ) throws -> ModelPricing {
        let longContext = longContextJSON.map { ", \"long_context\": \($0)" } ?? ""
        let json = """
            {
              "pricing": {
                "tiered-model": {
                  "input_per_million": 0.1,
                  "output_per_million": 0.5,
                  "cache_write_per_million": 0.125,
                  "cache_read_per_million": 0.01\(longContext)
                }
              },
              "fast_multipliers_exact": {"tiered-model": 2},
              "alias_rules": []
            }
            """
        return ModelPricing(
            supplement: try PricingSupplement.decode(from: Data(json.utf8)),
            primary: PricingCatalog(), secondary: PricingCatalog())
    }
}
