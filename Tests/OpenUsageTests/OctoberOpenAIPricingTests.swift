import XCTest

@testable import OpenUsage

final class OctoberOpenAIPricingTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testTerraUsesPublishedRatesForCanonicalAndLogAliases() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "gpt-6.1-terra"))
        XCTAssertEqual(rates.inputPerMillion, 1)
        XCTAssertEqual(rates.cacheWritePerMillion, 1.25)
        XCTAssertEqual(rates.cacheReadPerMillion, 0.05)
        XCTAssertEqual(rates.outputPerMillion, 5)

        for prefix in ["", "openai/"] {
            for effort in ["", "-none", "-low", "-medium", "-high", "-xhigh", "-max"] {
                for date in ["", "-20261026", "-2026-10-26"] {
                    let name = prefix + "gpt-6.1-terra" + effort
                    XCTAssertEqual(pricing.resolve(model: name + date), rates, name + date)
                    for separator in ["-", ".", "@"] {
                        let fast = name + separator + "fast" + date
                        XCTAssertEqual(pricing.resolve(model: fast), rates.scaled(by: 2), fast)
                    }
                }
            }
        }
        XCTAssertEqual(pricing.resolve(model: "openai/GPT-6.1-TERRA-high"), rates)
        XCTAssertNil(pricing.resolve(model: "gpt-6.1-terra-ultrafast"))
        XCTAssertNil(CodexUsagePricing.estimate(
            model: "gpt-6.1-terra", tokens: .init(input: 1_000), pricing: pricing, isUltrafast: true))
    }

    func testTerraLongContextBoundaryIncludesCacheTokensButNotOutput() throws {
        let cases: [(TokenBreakdown, Double)] = [
            (.init(input: 272_000, output: 1_000), 0.277),
            (.init(input: 272_001, output: 1_000), 0.551502),
            (.init(input: 200_000, cacheRead: 72_000, output: 1_000), 0.2086),
            (.init(input: 200_001, cacheRead: 72_000, output: 1_000), 0.414702),
            (.init(input: 200_000, cacheWrite5m: 72_000, output: 1_000), 0.295),
            (.init(input: 200_001, cacheWrite5m: 72_000, output: 1_000), 0.587502),
            (.init(input: 200_000, cacheWrite5m: 50_000, cacheRead: 22_000, output: 1_000), 0.2686),
            (.init(input: 200_001, cacheWrite5m: 50_000, cacheRead: 22_000, output: 1_000), 0.534702),
            (.init(input: 1, output: 300_000), 1.500001),
        ]
        for model in ["gpt-6.1-terra", "openai/gpt-6.1-terra-none-20261026", "gpt-6.1-terra-max"] {
            for (tokens, expected) in cases {
                XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                    model: model, tokens: tokens, pricing: pricing)), expected, accuracy: 1e-9, model)
            }
        }
    }

    func testTerraFastAliasesAndRequestMetadataApplyMultiplierOnce() throws {
        let cases: [(TokenBreakdown, Double)] = [
            (.init(input: 200_000, cacheRead: 72_000, output: 1_000), 0.4172),
            (.init(input: 200_001, cacheRead: 72_000, output: 1_000), 0.829404),
        ]
        for (tokens, expected) in cases {
            var fastTokens = tokens
            fastTokens.isFast = true
            for base in ["gpt-6.1-terra", "openai/gpt-6.1-terra-none"] {
                XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                    model: base, tokens: fastTokens, pricing: pricing)), expected, accuracy: 1e-9, base)
                for separator in ["-", ".", "@"] {
                    let alias = base + separator + "fast-20261026"
                    for request in [tokens, fastTokens] {
                        XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                            model: alias, tokens: request, pricing: pricing)), expected, accuracy: 1e-9, alias)
                    }
                }
            }
        }
    }

    func testSolUltrafastUsesExplicitRatesAndNeverAddsFastMultiplier() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "gpt-6.1-sol-ultrafast"))
        XCTAssertEqual(rates.inputPerMillion, 12)
        XCTAssertEqual(rates.cacheWritePerMillion, 15)
        XCTAssertEqual(rates.cacheReadPerMillion, 0.6)
        XCTAssertEqual(rates.outputPerMillion, 60)

        let cases: [(TokenBreakdown, Double)] = [
            (.init(input: 200_000, cacheWrite5m: 50_000, cacheRead: 22_000, output: 1_000), 3.2232),
            (.init(input: 200_001, cacheWrite5m: 50_000, cacheRead: 22_000, output: 1_000), 6.416424),
        ]
        for (tokens, expected) in cases {
            for fast in [false, true] {
                var request = tokens
                request.isFast = fast
                for base in ["gpt-6.1-sol", "openai/gpt-6.1-sol-max"] {
                    XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                        model: base + "-20261008", tokens: request, pricing: pricing, isUltrafast: true
                    )), expected, accuracy: 1e-9, base)
                    for separator in ["-", ".", "@"] {
                        let alias = base + separator + "ultrafast-20261008"
                        XCTAssertEqual(pricing.resolve(model: alias), rates, alias)
                        for tierMetadata in [false, true] {
                            XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                                model: alias, tokens: request, pricing: pricing, isUltrafast: tierMetadata
                            )), expected, accuracy: 1e-9, alias)
                        }
                    }
                }
            }
        }
        XCTAssertNil(CodexUsagePricing.estimate(
            model: "gpt-6.1-sol-ultrafast-fast", tokens: .init(input: 1_000), pricing: pricing))
    }

    func testRosalindUsesPublishedTextRatesWithoutLongContextSurcharge() throws {
        for model in ["gpt-rosalind-research", "gpt-rosalind-discovery"] {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, 5, model)
            XCTAssertEqual(rates.cacheWritePerMillion, 5, model)
            XCTAssertEqual(rates.cacheReadPerMillion, 0.5, model)
            XCTAssertEqual(rates.outputPerMillion, 25, model)
            let tokens = TokenBreakdown(input: 300_000, cacheRead: 100_000, output: 10_000)
            XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                model: model, tokens: tokens, pricing: pricing)), 1.8, accuracy: 1e-9, model)
        }
    }

    func testLegacyReasoningFastRatesUseTheirPublishedMultipliers() throws {
        let cases: [(String, Double, Double, Double, Double)] = [
            ("o3", 1.75, 3.5, 0.875, 14),
            ("o4-mini", 20.0 / 11.0, 2, 0.5, 8),
        ]
        for (model, multiplier, input, read, output) in cases {
            for name in [model, "openai/" + model + "-2025-04-16"] {
                XCTAssertEqual(try XCTUnwrap(pricing.supplement.fastMultiplier(for: name)),
                               multiplier, accuracy: 1e-9, name)
                let rates = try XCTUnwrap(pricing.resolve(model: name + "-fast"), name)
                XCTAssertEqual(rates.inputPerMillion, input, accuracy: 1e-9, name)
                XCTAssertEqual(rates.cacheReadPerMillion, read, accuracy: 1e-9, name)
                XCTAssertEqual(rates.outputPerMillion, output, accuracy: 1e-9, name)
                for fastAlias in [false, true] {
                    let tokens = TokenBreakdown(input: 1_000, cacheRead: 1_000, output: 1_000, isFast: true)
                    XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                        model: name + (fastAlias ? "-fast" : ""), tokens: tokens, pricing: pricing
                    )), (input + read + output) / 1_000, accuracy: 1e-9, name)
                }
            }
        }
    }
}
