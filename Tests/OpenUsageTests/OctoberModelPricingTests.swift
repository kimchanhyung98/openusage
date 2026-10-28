import XCTest
@testable import OpenUsage

final class OctoberModelPricingTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testClaude55PublishedRates() throws {
        let cases: [(String, Double, Double, Double, Double)] = [
            ("claude-opus-5-5", 4, 5, 0.2, 20),
            ("claude-opus-5-5-fast", 8, 10, 0.4, 40),
            ("claude-sonnet-5-5", 2, 2.5, 0.1, 10),
            ("claude-haiku-5-5", 0.1, 0.125, 0.01, 0.5),
            ("claude-mythos-5-1", 10, 12.5, 0.25, 50)
        ]
        for (model, input, write, read, output) in cases {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, input, model)
            XCTAssertEqual(rates.cacheWritePerMillion, write, model)
            XCTAssertEqual(rates.cacheReadPerMillion, read, model)
            XCTAssertEqual(rates.outputPerMillion, output, model)
        }
    }

    func testClaude55AliasesAndFastRequestSignalUseSameCost() throws {
        let standard = try XCTUnwrap(pricing.resolve(model: "claude-opus-5-5"))
        let fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-5-5-fast"))
        XCTAssertEqual(pricing.resolve(model: "anthropic/claude-opus-5.5[1m]-thinking-high"), standard)
        XCTAssertEqual(pricing.resolve(model: "claude-5.5-opus-high-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5-5-fast-20260922"), fast)
        XCTAssertEqual(
            pricing.resolve(model: "anthropic/claude-sonnet-5.5-thinking-high"),
            pricing.resolve(model: "claude-sonnet-5-5")
        )

        let tokens = TokenBreakdown(
            input: 200_000, cacheWrite5m: 100_000, cacheWrite1h: 100_000,
            cacheRead: 500_000, output: 20_000
        )
        var fastTokens = tokens
        fastTokens.isFast = true
        XCTAssertEqual(standard.costDollars(for: tokens), 2.6, accuracy: 1e-9)
        XCTAssertEqual(standard.costDollars(for: fastTokens), 5.2, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: tokens), 5.2, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: fastTokens), 5.2, accuracy: 1e-9)
    }

    func testHaiku55ThresholdCountsEveryPromptBucketAndRepricesWholeRequest() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "anthropic/claude-haiku-5.5"))
        XCTAssertEqual(rates.longContextThresholdTokens, 100_000)
        let boundary = TokenBreakdown(
            input: 25_000, cacheWrite5m: 25_000, cacheWrite1h: 25_000,
            cacheRead: 25_000, output: 10_000
        )
        var over = boundary
        over.cacheRead += 1

        XCTAssertEqual(rates.costDollars(for: boundary), 0.015875, accuracy: 1e-12)
        XCTAssertEqual(rates.costDollars(for: over), 0.07937505, accuracy: 1e-12)
        XCTAssertEqual(rates.costDollars(for: over, applyLongContextRates: false), 0.01587501, accuracy: 1e-12)
        XCTAssertEqual(
            rates.costDollars(for: TokenBreakdown(input: 100_000, output: 500_000)),
            0.26, accuracy: 1e-12
        )
    }

    func testSonnet5DiscountOverridesStalePrimaryCatalog() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "anthropic/claude-sonnet-5-thinking-high"))
        XCTAssertEqual(rates.inputPerMillion, 2)
        XCTAssertEqual(rates.outputPerMillion, 10)
        XCTAssertEqual(rates.cacheWritePerMillion, 2.5)
        XCTAssertEqual(rates.cacheReadPerMillion, 0.2)
        XCTAssertEqual(
            rates.costDollars(for: TokenBreakdown(input: 900_000, cacheRead: 100_000, output: 20_000)),
            2.02, accuracy: 1e-9
        )
    }

    func testGrok420DiscountAppliesToAllPublishedVariants() throws {
        for model in [
            "grok-4.20-0309-reasoning",
            "xai/grok-4.20-0309-non-reasoning",
            "grok-4.20-multi-agent-0309"
        ] {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, 1.25, model)
            XCTAssertEqual(rates.cacheReadPerMillion, 0.2, model)
            XCTAssertEqual(rates.outputPerMillion, 2.5, model)
            XCTAssertEqual(
                rates.costDollars(for: TokenBreakdown(input: 150_000, cacheRead: 50_000, output: 10_000)),
                0.2225, accuracy: 1e-9, model
            )
            XCTAssertEqual(
                rates.costDollars(for: TokenBreakdown(input: 150_001, cacheRead: 50_000, output: 10_000)),
                0.4450025, accuracy: 1e-9, model
            )
        }
    }

    func testGrok47FastLongContextUsesExplicitRates() throws {
        let standard = try XCTUnwrap(pricing.resolve(model: "xai/grok-4.7-high"))
        let fast = try XCTUnwrap(pricing.resolve(model: "grok-4-7-fast-high"))
        XCTAssertEqual(standard.longContextThresholdTokens, 200_000)
        XCTAssertEqual(fast.longContextThresholdTokens, 200_000)
        XCTAssertEqual(fast.inputPerMillion, 4)
        XCTAssertEqual(fast.cacheReadPerMillion, 1)
        XCTAssertEqual(fast.outputPerMillion, 12)

        let boundary = TokenBreakdown(input: 100_000, cacheRead: 100_000, output: 10_000)
        var over = boundary
        over.input += 1
        XCTAssertEqual(standard.costDollars(for: boundary), 0.31, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: boundary), 0.62, accuracy: 1e-9)
        XCTAssertEqual(standard.costDollars(for: over), 0.620004, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: over), 0.930006, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: over), standard.costDollars(for: over) * 1.5, accuracy: 1e-9)
    }

    func testGrokLatestAliasesUseCurrentModelAndCacheDiscount() throws {
        let rates = try XCTUnwrap(pricing.resolve(model: "grok-4.5"))
        XCTAssertEqual(rates.cacheReadPerMillion, 0.3)
        for model in ["grok-4.5-latest", "grok-build-latest", "xai/grok-build-latest"] {
            XCTAssertEqual(pricing.resolve(model: model), rates, model)
            XCTAssertEqual(
                try XCTUnwrap(pricing.estimatedCostDollars(
                    model: model,
                    tokens: TokenBreakdown(input: 50_000, cacheRead: 100_000, output: 10_000)
                )),
                0.19, accuracy: 1e-9, model
            )
        }
    }

    func testGooglePromotionalRatesAndOfficialRoutingAliases() throws {
        let cases: [(String, Double, Double, Double)] = [
            ("gemini-4-argon", 2, 0.1, 10),
            ("gemini-3.8-flash", 0.75, 0.075, 3.75),
            ("gemini-3.6-flash", 0.75, 0.075, 3.75),
            ("gemini-3.5-flash-lite", 0.3, 0.03, 2.5)
        ]
        for (model, input, read, output) in cases {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, input, model)
            XCTAssertEqual(rates.cacheReadPerMillion, read, model)
            XCTAssertEqual(rates.outputPerMillion, output, model)
        }
        XCTAssertEqual(pricing.resolve(model: "google/gemini-4-argon-high"), pricing.resolve(model: "gemini-4-argon"))
        XCTAssertEqual(pricing.resolve(model: "gemini-3.5-flash"), pricing.resolve(model: "gemini-3.6-flash"))
        XCTAssertEqual(pricing.resolve(model: "google/gemini-3.7-flash-preview"), pricing.resolve(model: "gemini-3.8-flash"))
        for model in ["gemini-3.6-flash-20260101", "gemini-4-argon-audio", "gemini-3.8-flash-fast"] {
            XCTAssertNil(pricing.supplement.canonicalName(for: model), model)
        }
    }

    func testKimi31HighspeedKeepsSameCacheReadRate() throws {
        let standard = try XCTUnwrap(pricing.resolve(model: "moonshot/kimi-k3.1-pro"))
        let highspeed = try XCTUnwrap(pricing.resolve(model: "moonshotai/kimi-k3.1-pro-highspeed"))
        XCTAssertEqual(standard.inputPerMillion, 2)
        XCTAssertEqual(standard.cacheWritePerMillion, 2)
        XCTAssertEqual(standard.outputPerMillion, 10)
        XCTAssertEqual(highspeed.inputPerMillion, 4)
        XCTAssertEqual(highspeed.cacheWritePerMillion, 4)
        XCTAssertEqual(highspeed.outputPerMillion, 20)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.2)
        XCTAssertEqual(highspeed.cacheReadPerMillion, 0.2)
        let tokens = TokenBreakdown(input: 100_000, cacheRead: 900_000, output: 10_000)
        XCTAssertEqual(standard.costDollars(for: tokens), 0.48, accuracy: 1e-9)
        XCTAssertEqual(highspeed.costDollars(for: tokens), 0.78, accuracy: 1e-9)
    }

    func testGLMFlashFamilyAndMusePublishedRates() throws {
        let cases: [(String, Double, Double, Double)] = [
            ("zai/glm-5.3-flash", 0.15, 0.03, 0.5),
            ("glm-5.3-flashx", 0.37, 0.075, 1.25),
            ("z-ai/glm-5.3-flashx-legal", 0.37, 0.075, 1.25),
            ("meta/muse-wonder-1.0-high", 4, 0.2, 20)
        ]
        for (model, input, read, output) in cases {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, input, model)
            XCTAssertEqual(rates.cacheReadPerMillion, read, model)
            XCTAssertEqual(rates.outputPerMillion, output, model)
        }
    }
}
