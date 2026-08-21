import XCTest
@testable import OpenUsage

final class PricingBundledResourceTests: XCTestCase {
    private static let pricing = TestPricing.bundled

    func testBundledResourcesLoadAndAreNonTrivial() {
        let pricing = Self.pricing
        XCTAssertGreaterThan(pricing.primary.entries.count, 500, "LiteLLM snapshot suspiciously small")
        XCTAssertGreaterThan(pricing.secondary.entries.count, 500, "models.dev snapshot suspiciously small")
        XCTAssertFalse(pricing.supplement.pricing.isEmpty)
        XCTAssertFalse(pricing.supplement.aliasRules.isEmpty)
    }

    func testEveryAliasCanonicalResolves() {
        let pricing = Self.pricing
        for rule in pricing.supplement.aliasRules {
            XCTAssertNotNil(
                pricing.resolve(model: rule.canonical),
                "alias canonical '\(rule.canonical)' resolves against no pricing source"
            )
        }
    }

    func testEveryFastMultiplierBaseResolves() {
        let pricing = Self.pricing
        for base in Self.pricing.supplement.fastMultipliers.keys {
            XCTAssertNotNil(pricing.resolve(model: base), "fast-multiplier base '\(base)' resolves nowhere")
        }
    }

    /// Cursor CSV slug 실측 확인 — provider가 재가격 책정하면 상수 갱신 필요
    func testKnownCursorSlugsPriceCorrectly() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
        XCTAssertEqual(pricing.resolve(model: "claude-4.5-sonnet-thinking")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "claude-4.6-opus-max-thinking")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "claude-4.6-opus-max-thinking-fast")?.inputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-xhigh-fast")?.inputPerMillion, 12.5)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-sol-ultra")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-sol-ultra-fast")?.inputPerMillion, 10)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-terra-high")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-terra-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-luna")?.inputPerMillion, 0.2)
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-luna-fast")?.inputPerMillion, 0.4)
        XCTAssertEqual(pricing.resolve(model: "grok-4-20-thinking")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5")?.inputPerMillion, 2)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-high")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-high-fast")?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p5")?.inputPerMillion, 0.6)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2.7-code")?.inputPerMillion, 0.95)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7")?.inputPerMillion, 0.95)
        XCTAssertEqual(pricing.resolve(model: "claude-4.7-opus-high-thinking")?.inputPerMillion, 5)
        XCTAssertEqual(pricing.resolve(model: "claude-4.7-opus-max-thinking-fast")?.inputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "glm-5.2-max")?.inputPerMillion, 1.4)
        XCTAssertEqual(pricing.resolve(model: "github_bugbot")?.outputPerMillion, 30)
        XCTAssertEqual(pricing.resolve(model: "Premium (GPT-5.3-Codex)")?.inputPerMillion, 1.75)
    }

    /// log에 그대로 등장하는 raw model id (alias rewriting 없음)
    func testKnownLogModelIDsPriceCorrectly() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-4-1-20250805")?.inputPerMillion, 15)
        XCTAssertNotNil(pricing.resolve(model: "gpt-5.1-codex"))
        XCTAssertEqual(pricing.resolve(model: "grok-build-0.1")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "grok-4.3")?.inputPerMillion, 1.25)
    }

    func testClaudeFable5PricingAndAliases() throws {
        let pricing = Self.pricing
        let fable = try XCTUnwrap(pricing.resolve(model: "claude-fable-5-thinking"))
        XCTAssertEqual(pricing.resolve(model: "claude-fable-5-thinking-xhigh"), fable)
        XCTAssertEqual(fable.inputPerMillion, 10.0)
        XCTAssertEqual(fable.outputPerMillion, 50.0)

        let opus48 = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8"))
        XCTAssertEqual(fable.inputPerMillion, opus48.inputPerMillion * 2)
        XCTAssertEqual(fable.outputPerMillion, opus48.outputPerMillion * 2)
    }

    func testClaudeSonnet5PricingAndAliases() throws {
        let pricing = Self.pricing
        let sonnet5 = try XCTUnwrap(pricing.resolve(model: "claude-sonnet-5-thinking-high"))
        XCTAssertEqual(sonnet5.inputPerMillion, 3.0)
        XCTAssertEqual(sonnet5.outputPerMillion, 15.0)
        XCTAssertEqual(sonnet5.cacheWritePerMillion, 3.75)
        XCTAssertEqual(sonnet5.cacheReadPerMillion, 0.3)

        let sonnet46 = try XCTUnwrap(pricing.resolve(model: "claude-4.6-sonnet"))
        XCTAssertEqual(sonnet5.inputPerMillion, sonnet46.inputPerMillion)
        XCTAssertEqual(sonnet5.outputPerMillion, sonnet46.outputPerMillion)
    }

    func testClaudeOpus5PricingAndAliases() throws {
        let pricing = Self.pricing
        let opus5 = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(opus5.inputPerMillion, 5.0)
        XCTAssertEqual(opus5.cacheWritePerMillion, 6.25)
        XCTAssertEqual(opus5.cacheReadPerMillion, 0.5)
        XCTAssertEqual(opus5.outputPerMillion, 25.0)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5[1m]"), opus5)
        XCTAssertEqual(pricing.resolve(model: "claude-opus-5-thinking-xhigh"), opus5)

        let opus5Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-5[1m]-thinking-high-fast"))
        XCTAssertEqual(opus5Fast.inputPerMillion, opus5.inputPerMillion * 2)
        XCTAssertEqual(opus5Fast.cacheWritePerMillion, opus5.cacheWritePerMillion * 2)
        XCTAssertEqual(opus5Fast.cacheReadPerMillion, opus5.cacheReadPerMillion * 2)
        XCTAssertEqual(opus5Fast.outputPerMillion, opus5.outputPerMillion * 2)

        let opus48 = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8"))
        XCTAssertEqual(opus5.inputPerMillion, opus48.inputPerMillion)
        XCTAssertEqual(opus5.outputPerMillion, opus48.outputPerMillion)
        XCTAssertEqual(opus5.fastMultiplier, opus48.fastMultiplier)
    }

    func testClaudeOpus5FastModeBillsAtTwiceBaseRate() throws {
        let pricing = Self.pricing
        let opus5 = try XCTUnwrap(pricing.resolve(model: "claude-opus-5"))
        XCTAssertEqual(opus5.fastMultiplier, 2.0)

        let tokens = TokenBreakdown(
            input: 1_000_000,
            cacheWrite5m: 1_000_000,
            cacheWrite1h: 1_000_000,
            cacheRead: 1_000_000,
            output: 1_000_000
        )
        XCTAssertEqual(opus5.costDollars(for: tokens), 46.75, accuracy: 0.000_001)

        var fastTokens = tokens
        fastTokens.isFast = true
        XCTAssertEqual(opus5.costDollars(for: fastTokens), 93.5, accuracy: 0.000_001)
    }

    func testGPT56PricingAndAliases() throws {
        let pricing = Self.pricing
        let sol = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-sol-ultra"))
        XCTAssertEqual(sol.inputPerMillion, 5.0)
        XCTAssertEqual(sol.cacheWritePerMillion, 6.25)
        XCTAssertEqual(sol.cacheReadPerMillion, 0.5)
        XCTAssertEqual(sol.outputPerMillion, 30.0)
        let solFast = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-sol-ultra-fast"))
        XCTAssertEqual(solFast.inputPerMillion, 10.0)
        XCTAssertEqual(solFast.cacheWritePerMillion, 12.5)
        XCTAssertEqual(solFast.cacheReadPerMillion, 1.0)
        XCTAssertEqual(solFast.outputPerMillion, 60.0)

        let terra = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-terra-high"))
        XCTAssertEqual(terra.inputPerMillion, 2.0)
        XCTAssertEqual(terra.cacheWritePerMillion, 2.5)
        XCTAssertEqual(terra.cacheReadPerMillion, 0.2)
        XCTAssertEqual(terra.outputPerMillion, 12.0)
        let terraFast = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-terra-high-fast"))
        XCTAssertEqual(terraFast.inputPerMillion, 4.0)
        XCTAssertEqual(terraFast.cacheWritePerMillion, 5.0)
        XCTAssertEqual(terraFast.cacheReadPerMillion, 0.4)
        XCTAssertEqual(terraFast.outputPerMillion, 24.0)

        let luna = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-luna"))
        XCTAssertEqual(luna.inputPerMillion, 0.2)
        XCTAssertEqual(luna.cacheWritePerMillion, 0.25)
        XCTAssertEqual(luna.cacheReadPerMillion, 0.02)
        XCTAssertEqual(luna.outputPerMillion, 1.2)
        let lunaFast = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-luna-fast"))
        XCTAssertEqual(lunaFast.inputPerMillion, 0.4)
        XCTAssertEqual(lunaFast.cacheWritePerMillion, 0.5)
        XCTAssertEqual(lunaFast.cacheReadPerMillion, 0.04)
        XCTAssertEqual(lunaFast.outputPerMillion, 2.4)

        let cyber = try XCTUnwrap(pricing.resolve(model: "gpt-5.6-cyber"))
        XCTAssertEqual(cyber.inputPerMillion, 12.5)
        XCTAssertEqual(cyber.cacheWritePerMillion, 15.625)
        XCTAssertEqual(cyber.cacheReadPerMillion, 1.25)
        XCTAssertEqual(cyber.outputPerMillion, 75.0)
    }

    func testOpusFastModeSupplementOverrides() throws {
        let pricing = Self.pricing
        let opus47Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-7-thinking-high-fast"))
        XCTAssertEqual(opus47Fast.inputPerMillion, 30)
        XCTAssertEqual(opus47Fast.cacheWritePerMillion, 37.5)
        XCTAssertEqual(opus47Fast.cacheReadPerMillion, 3)
        XCTAssertEqual(opus47Fast.outputPerMillion, 150)

        let opus48Fast = try XCTUnwrap(pricing.resolve(model: "claude-opus-4-8-thinking-high-fast"))
        XCTAssertEqual(opus48Fast.inputPerMillion, opus47Fast.inputPerMillion / 3)
        XCTAssertEqual(opus48Fast.outputPerMillion, opus47Fast.outputPerMillion / 3)
    }

    func testGLM52PricingAndAliases() throws {
        let pricing = Self.pricing
        let glm = try XCTUnwrap(pricing.resolve(model: "glm-5.2-max"))
        XCTAssertEqual(glm.inputPerMillion, 1.4)
        XCTAssertEqual(glm.cacheWritePerMillion, 1.4)
        XCTAssertEqual(glm.cacheReadPerMillion, 0.26)
        XCTAssertEqual(glm.outputPerMillion, 4.4)

        let outputOnly = TokenBreakdown(output: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "glm-5.2-high", tokens: outputOnly)!, 4.4, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "glm-5.2-bogus", tokens: outputOnly))
    }

    func testGrokCLIModelAliases() {
        let pricing = Self.pricing
        XCTAssertEqual(pricing.resolve(model: "grok-build")?.inputPerMillion, 1)
        XCTAssertEqual(pricing.resolve(model: "grok-composer-2.5-fast")?.inputPerMillion, 3)
    }

    func testGrok45PricingAndAliases() throws {
        let pricing = Self.pricing
        let standard = try XCTUnwrap(pricing.resolve(model: "grok-4.5-high"))
        XCTAssertEqual(standard.inputPerMillion, 2.0)
        XCTAssertEqual(standard.cacheWritePerMillion, 2.0)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.5)
        XCTAssertEqual(standard.outputPerMillion, 6.0)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-low"), standard)

        let fast = try XCTUnwrap(pricing.resolve(model: "grok-4.5-fast"))
        XCTAssertEqual(fast.inputPerMillion, 4.0)
        XCTAssertEqual(fast.cacheWritePerMillion, 4.0)
        XCTAssertEqual(fast.cacheReadPerMillion, 1.0)
        XCTAssertEqual(fast.outputPerMillion, 18.0)
        // Cursor CSV는 fast-before-effort 순서, effort-before-fast도 허용
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-high"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-medium"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-fast-xhigh"), fast)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-xhigh"), standard)
        XCTAssertEqual(pricing.resolve(model: "grok-4.5-medium-fast"), fast)
        // Cursor usage export는 first-party Grok에 `cursor-` prefix를 붙이기도 함
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-high-fast"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-fast-high"), fast)
        XCTAssertEqual(pricing.resolve(model: "cursor-grok-4.5-high"), standard)
    }

    func testKimiK27CodePricingAndAliases() throws {
        let pricing = Self.pricing
        let kimi = try XCTUnwrap(pricing.resolve(model: "kimi-k2.7-code"))
        XCTAssertEqual(kimi.inputPerMillion, 0.95)
        XCTAssertEqual(kimi.cacheWritePerMillion, 0.95)
        XCTAssertEqual(kimi.cacheReadPerMillion, 0.19)
        XCTAssertEqual(kimi.outputPerMillion, 4.0)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2.7"), kimi)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7"), kimi)
        XCTAssertEqual(pricing.resolve(model: "kimi-k2p7-code"), kimi)
    }

    func testCostSumsAllBucketsAndUnpricedIsNil() throws {
        let pricing = Self.pricing
        let entry = try XCTUnwrap(pricing.resolve(model: "composer-1"))
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        let expected = entry.inputPerMillion + entry.cacheWritePerMillion + entry.cacheReadPerMillion + entry.outputPerMillion
        XCTAssertEqual(pricing.estimatedCostDollars(model: "composer-1", tokens: tokens)!, expected, accuracy: 1e-9)
        XCTAssertNil(pricing.estimatedCostDollars(model: "nope", tokens: tokens))
    }
}
