import XCTest

@testable import OpenUsage

final class PricingSupplementCompatibilityTests: XCTestCase {
    func testOptionalExactMultipliersDecodeAndTakePrecedenceForDeclaredModels() throws {
        let json = #"""
            {
              "pricing": {
                "gpt-5-mini": {"input_per_million": 0.25, "output_per_million": 2}
              },
              "fast_multipliers": {"gpt-5": 2},
              "fast_multipliers_exact": {"gpt-5-mini": 1.8},
              "alias_rules": []
            }
            """#
        let supplement = try PricingSupplement.decode(from: Data(json.utf8))

        XCTAssertEqual(supplement.pricing["gpt-5-mini"]?.fastMultiplier, 1.8)
        XCTAssertEqual(supplement.fastMultipliers, ["gpt-5": 2])
        for prefix in ["", "openai/"] {
            for date in ["", "-20260929", "-2026-09-29"] {
                XCTAssertEqual(supplement.fastMultiplier(for: prefix + "gpt-5-mini" + date), 1.8)
            }
        }
        XCTAssertEqual(supplement.fastMultiplier(for: "openai/gpt-5-20260929"), 2)
    }

    func testLegacyFeedWithoutExactMultipliersRetainsItsExistingBehavior() throws {
        let json = #"""
            {
              "pricing": {"gpt-5": {"input_per_million": 1.25, "output_per_million": 10}},
              "fast_multipliers": {"gpt-5": 2},
              "alias_rules": []
            }
            """#
        let supplement = try PricingSupplement.decode(from: Data(json.utf8))

        XCTAssertEqual(supplement.pricing["gpt-5"]?.fastMultiplier, 2)
        XCTAssertEqual(supplement.fastMultiplier(for: "gpt-5"), 2)
        XCTAssertEqual(supplement.fastMultiplier(for: "openai/gpt-5-mini-20260929"), 2)

        let empty = try PricingSupplement.decode(from: Data(#"{"pricing":{},"alias_rules":[]}"#.utf8))
        XCTAssertNil(empty.fastMultiplier(for: "gpt-5"))
    }

    func testBundledNewMultipliersUseTheOptionalFieldAndKeepLegacyFeedKeysUnchanged() throws {
        let url = try XCTUnwrap(Bundle.openUsageResources.url(forResource: "pricing_supplement", withExtension: "json"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let legacy = try XCTUnwrap(object["fast_multipliers"] as? [String: Double])
        let exact = try XCTUnwrap(object["fast_multipliers_exact"] as? [String: Double])
        let expectedLegacy: [String: Double] = [
            "gpt-6-astra": 2, "claude-opus-5": 2, "gpt-5": 2,
            "gpt-5.1-codex": 2, "gpt-5.1-codex-max": 2, "gpt-5.2": 2,
            "gpt-5.2-codex": 2, "gpt-5.3-codex": 2, "gpt-5.4": 2, "gpt-5.5": 2.5,
            "gpt-5.6-sol": 2, "gpt-5.6-terra": 2, "gpt-5.6-luna": 2,
        ]
        let expectedExact: [String: Double] = [
            "gpt-6.1-sol": 2, "gpt-6-sol": 2, "gpt-6-luna": 2, "gpt-5.4-mini": 2,
            "gpt-5.1": 2, "gpt-5-mini": 1.8, "gpt-4.1": 1.75, "gpt-4.1-mini": 1.75,
            "gpt-4.1-nano": 2, "gpt-4o": 1.7, "gpt-4o-2024-05-13": 1.75,
            "gpt-4o-mini": 1.6666666666666667,
        ]

        XCTAssertEqual(legacy, expectedLegacy)
        XCTAssertEqual(exact, expectedExact)
        XCTAssertTrue(Set(legacy.keys).isDisjoint(with: exact.keys))
        for base in exact.keys {
            XCTAssertNotNil(TestPricing.bundled.resolve(model: base), base)
        }
    }

    func testDeclaredGpt4MultipliersAcceptQualifiedDatesAndPreserveMayException() {
        let supplement = TestPricing.bundled.supplement
        let cases: [(String, Double)] = [
            ("gpt-4o", 1.7), ("gpt-4o-mini", 1.6666666666666667),
            ("gpt-4.1", 1.75), ("gpt-4.1-mini", 1.75), ("gpt-4.1-nano", 2),
        ]
        for (base, multiplier) in cases {
            for prefix in ["", "openai/"] {
                for date in ["", "-20260929", "-2026-09-29"] {
                    let model = prefix + base + date
                    XCTAssertEqual(supplement.fastMultiplier(for: model), multiplier, model)
                }
            }
        }
        XCTAssertEqual(supplement.fastMultiplier(for: "gpt-4o-2024-05-13"), 1.75)
        XCTAssertEqual(supplement.fastMultiplier(for: "openai/gpt-4o-2024-05-13"), 1.75)
    }

    func testNewMultiplierScopeExcludesUndeclaredAudioSearchAndRealtimeModels() {
        let supplement = TestPricing.bundled.supplement
        for model in [
            "gpt-4o-audio-preview", "gpt-4o-search-preview", "gpt-4o-realtime-preview",
            "gpt-4o-mini-audio-preview", "gpt-4o-mini-search-preview", "gpt-4o-mini-realtime-preview",
        ] {
            for prefix in ["", "openai/"] {
                for date in ["", "-20260929", "-2026-09-29"] {
                    let qualified = prefix + model + date
                    XCTAssertNil(supplement.fastMultiplier(for: qualified), qualified)
                }
            }
        }
    }

    func testBundledUnsupportedFastVariantsStayUnpricedAndExplicitCatalogEntriesRemainAvailable() throws {
        let pricing = TestPricing.bundled
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)
        for base in ["gpt-4o-audio-preview", "gpt-4o-search-preview", "gpt-4o-realtime-preview"] {
            XCTAssertNotNil(pricing.resolve(model: base), base)
            let fast = base + "-fast"
            XCTAssertNil(pricing.resolve(model: fast), fast)
            for secondary in [false, true] {
                let catalog = PricingCatalog(entries: [fast: rates])
                let snapshot = ModelPricing(
                    supplement: pricing.supplement,
                    primary: secondary ? PricingCatalog() : catalog,
                    secondary: secondary ? catalog : PricingCatalog())
                XCTAssertEqual(snapshot.resolve(model: fast), rates, fast)
            }
        }
        XCTAssertNotNil(pricing.resolve(model: "gpt-4o"))
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "gpt-4o-fast", tokens: .init(input: 1_000))),
            0.00425, accuracy: 1e-9)
    }

    func testExactMultipliersRespectRegisteredMiniAliasesAndBeatLegacyGpt5Prefix() {
        let supplement = TestPricing.bundled.supplement
        for model in ["gpt-5.4-mini-high", "openai/GPT-5.4-MINI-high-20260929"] {
            XCTAssertEqual(supplement.fastMultiplier(for: model), 2, model)
        }
        for prefix in ["", "openai/"] {
            for date in ["", "-20260929", "-2026-09-29"] {
                let model = prefix + "gpt-5-mini" + date
                XCTAssertEqual(supplement.fastMultiplier(for: model), 1.8, model)
            }
        }
    }
}
