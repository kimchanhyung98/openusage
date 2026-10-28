import XCTest

@testable import OpenUsage

final class PricingSupplementVersionTests: XCTestCase {
    func testVersionTwoPricesOverrideLegacyEntriesAndRetainOtherModels() throws {
        let supplement = try PricingSupplement.decode(from: fixture)

        XCTAssertEqual(Set(supplement.pricing.keys), ["model", "legacy-only", "new-model"])
        XCTAssertEqual(supplement.pricing["model"]?.inputPerMillion, 2)
        XCTAssertEqual(supplement.pricing["legacy-only"]?.inputPerMillion, 3)
        let newRates = try XCTUnwrap(supplement.pricing["new-model"])
        XCTAssertEqual(newRates.longContextThresholdTokens, 100_000)
        XCTAssertEqual(newRates.costDollars(for: .init(input: 100_001, output: 1_000)), 0.0525005, accuracy: 1e-12)
    }

    func testVersionTwoAliasesTakePrecedenceAndLegacyAliasesStillResolve() throws {
        let supplement = try PricingSupplement.decode(from: fixture)

        XCTAssertEqual(supplement.canonicalName(for: "log-model"), "model")
        XCTAssertEqual(supplement.canonicalName(for: "log-new"), "new-model")
        XCTAssertEqual(supplement.canonicalName(for: "log-legacy"), "legacy-only")
    }

    func testLegacyDecoderIgnoresVersionTwoPricesAndAliases() throws {
        let legacy = try JSONDecoder().decode(LegacySupplement.self, from: fixture)

        XCTAssertEqual(Set(legacy.pricing.keys), ["model", "legacy-only"])
        XCTAssertEqual(legacy.pricing["model"]?.inputPerMillion, 1)
        XCTAssertEqual(legacy.aliasRules.map(\.canonical), ["legacy-only", "legacy-only"])
        XCTAssertEqual(legacy.aliasRules.map(\.pattern), ["^log-model$", "^log-legacy$"])
    }

    func testMissingVersionTwoFieldsPreserveLegacyResolution() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
        object.removeValue(forKey: "pricing_v2")
        object.removeValue(forKey: "alias_rules_v2")
        let supplement = try PricingSupplement.decode(from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(Set(supplement.pricing.keys), ["model", "legacy-only"])
        XCTAssertEqual(supplement.pricing["model"]?.inputPerMillion, 1)
        XCTAssertEqual(supplement.canonicalName(for: "log-model"), "legacy-only")
        XCTAssertNil(supplement.canonicalName(for: "log-new"))
    }

    func testMalformedVersionTwoContainersAreRejected() throws {
        for section in ["pricing_v2", "alias_rules_v2"] {
            let invalidContainers: [Any] = section == "pricing_v2"
                ? [NSNull(), [], true, "invalid"] : [NSNull(), [:], true, "invalid"]
            for invalid in invalidContainers {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture) as? [String: Any])
                object[section] = invalid
                XCTAssertThrowsError(
                    try PricingSupplement.decode(from: JSONSerialization.data(withJSONObject: object)),
                    "\(section): \(invalid)")
            }
        }
    }

    func testBundledLegacyFeedKeepsCursorRatesWhileModernFeedUsesAPIRates() throws {
        let url = try XCTUnwrap(Bundle.openUsageResources.url(forResource: "pricing_supplement", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let legacy = try JSONDecoder().decode(LegacySupplement.self, from: data)
        XCTAssertEqual(legacy.pricing["grok-4.5"]?.cacheReadPerMillion, 0.5)
        XCTAssertNil(legacy.pricing["claude-haiku-5-5"])

        let geminiRule = try XCTUnwrap(legacy.aliasRules.first { rule in
            "gemini-3.5-flash".range(of: rule.pattern, options: .regularExpression) != nil
        })
        XCTAssertEqual(geminiRule.canonical, "gemini-3.5-flash")

        let modern = try PricingSupplement.decode(from: data)
        XCTAssertEqual(modern.pricing["grok-4.5"]?.cacheReadPerMillion, 0.3)
        XCTAssertEqual(modern.canonicalName(for: "gemini-3.5-flash"), "gemini-3.6-flash")
        XCTAssertEqual(modern.pricing["claude-haiku-5-5"]?.longContextThresholdTokens, 100_000)
    }

    private var fixture: Data {
        Data(
            #"""
            {
              "pricing": {
                "model": {"input_per_million": 1, "output_per_million": 5},
                "legacy-only": {"input_per_million": 3, "output_per_million": 9}
              },
              "pricing_v2": {
                "model": {"input_per_million": 2, "output_per_million": 10},
                "new-model": {
                  "input_per_million": 0.1, "output_per_million": 0.5,
                  "long_context": {
                    "threshold_tokens": 100000,
                    "input_per_million": 0.5, "output_per_million": 2.5,
                    "cache_write_per_million": 0.625, "cache_read_per_million": 0.05
                  }
                }
              },
              "alias_rules": [
                {"pattern": "^log-model$", "canonical": "legacy-only"},
                {"pattern": "^log-legacy$", "canonical": "legacy-only"}
              ],
              "alias_rules_v2": [
                {"pattern": "^log-model$", "canonical": "model"},
                {"pattern": "^log-new$", "canonical": "new-model"}
              ]
            }
            """#.utf8)
    }
}

private struct LegacySupplement: Decodable {
    var pricing: [String: Entry]
    var aliasRules: [Rule]

    struct Entry: Decodable {
        var inputPerMillion: Double
        var outputPerMillion: Double
        var cacheReadPerMillion: Double?

        enum CodingKeys: String, CodingKey {
            case inputPerMillion = "input_per_million"
            case outputPerMillion = "output_per_million"
            case cacheReadPerMillion = "cache_read_per_million"
        }
    }

    struct Rule: Decodable {
        var pattern: String
        var canonical: String
    }

    enum CodingKeys: String, CodingKey {
        case pricing
        case aliasRules = "alias_rules"
    }
}
