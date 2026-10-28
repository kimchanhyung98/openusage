import XCTest
@testable import OpenUsage

final class CursorPricingContextTests: XCTestCase {
    func testSourceSpecificMemoDoesNotReuseAnotherProvidersRate() {
        let sourceOrders: [[ModelPricing.Source]] = [[.api, .cursor], [.cursor, .api]]
        for sources in sourceOrders {
            let pricing = makePricing(supplement: [
                "grok-4.5": rates(input: 2, cacheRead: 0.3, output: 6),
                "cursor/grok-4.5": rates(input: 2, cacheRead: 0.5, output: 6)
            ])

            for source in sources + sources {
                XCTAssertEqual(
                    pricing.resolve(model: "grok-4.5", source: source)?.cacheReadPerMillion,
                    source == .cursor ? 0.5 : 0.3
                )
            }
            XCTAssertEqual(pricing.resolve(model: "grok-4.5")?.cacheReadPerMillion, 0.3)
        }
    }

    func testCSVUsesCursorAliasWithoutChangingReportedModel() throws {
        let pricing = try makePricing(
            supplement: [
                "grok-4.5": rates(input: 2, cacheRead: 0.3, output: 6),
                "cursor/grok-4.5": rates(input: 2, cacheRead: 0.5, output: 6)
            ],
            aliases: [
                (#"^cursor/grok-4\.5-high$"#, "cursor/grok-4.5"),
                (#"^grok-4\.5-high$"#, "grok-4.5")
            ]
        )
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        2026-10-28T00:00:00Z,grok-4.5-high,0,0,1000000,0
        """

        let row = try XCTUnwrap(CursorUsageCSV.parse(csv: csv, pricing: pricing).rows.first)

        XCTAssertEqual(row.model, "grok-4.5-high")
        XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: row.model, tokens: row.tokens)),
            0.3,
            accuracy: 0.000_001
        )
    }

    func testCursorExactSupplementWinsWhenScopedAliasTargetIsMissing() throws {
        let pricing = try makePricing(
            supplement: ["cursor/model": rates(input: 4, cacheRead: 0.2, output: 20)],
            aliases: [(#"^cursor/model$"#, "missing-target")],
            primary: ["model": rates(input: 90, cacheRead: 90, output: 90)]
        )

        XCTAssertEqual(pricing.resolve(model: "model", source: .cursor)?.inputPerMillion, 4)
        XCTAssertEqual(pricing.resolve(model: "model")?.inputPerMillion, 90)
    }

    func testMissingCursorOverrideRetainsSharedAliasesAndFastRates() throws {
        let standard = rates(input: 2, cacheRead: 0.2, output: 10, fast: 2)
        let pricing = try makePricing(
            aliases: [
                (#"^cursor/model-high$"#, "missing-target"),
                (#"^model-high$"#, "model"),
                (#"^model-high-fast$"#, "model-fast")
            ],
            primary: ["model": standard]
        )

        XCTAssertEqual(pricing.resolve(model: "model-high", source: .cursor), standard)
        XCTAssertEqual(pricing.resolve(model: "model-high-fast", source: .cursor)?.inputPerMillion, 4)
    }

    func testScopedAliasCannotSelectCommunityCatalogEntry() throws {
        let pricing = try makePricing(
            aliases: [(#"^cursor/unlisted$"#, "reseller-only")],
            primary: ["reseller-only": rates(input: 99, cacheRead: 99, output: 99)]
        )

        XCTAssertNil(pricing.resolve(model: "unlisted", source: .cursor))
    }

    func testCursorScopeDoesNotBecomeAFuzzyCatalogSearchTerm() {
        let pricing = makePricing(primary: ["cursor": rates(input: 99, cacheRead: 99, output: 99)])

        XCTAssertNil(pricing.resolve(model: "unknown-model-9000", source: .cursor))
        XCTAssertNil(pricing.estimatedCostDollars(
            model: "unknown-model-9000", tokens: TokenBreakdown(input: 1_000), source: .cursor
        ))
    }

    func testCursorCSVDoesNotApplyRequestTierToAggregatedTokens() throws {
        var fast = rates(input: 4, cacheRead: 1, output: 12)
        fast.longContextThresholdTokens = 256_000
        fast.inputAbove200kPerMillion = 6
        fast.cacheWriteAbove200kPerMillion = 6
        fast.cacheReadAbove200kPerMillion = 1.5
        fast.outputAbove200kPerMillion = 18
        let pricing = makePricing(supplement: ["cursor/grok-4.7-fast": fast])
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        2026-10-28T00:00:00Z,grok-4.7-fast,0,300000,0,100000
        """

        let row = try XCTUnwrap(CursorUsageCSV.parse(csv: csv, pricing: pricing).rows.first)

        XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), 2.4, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: row.model, tokens: row.tokens, source: .cursor)),
            3.6,
            accuracy: 0.000_001
        )
    }

    func testBundledGrokCacheRatesFollowTheProvider() throws {
        let pricing = TestPricing.bundled
        let tokens = TokenBreakdown(cacheRead: 100_000)

        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "grok-4.5", tokens: tokens)),
            0.03,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "grok-4.5", tokens: tokens, source: .cursor)),
            0.05,
            accuracy: 0.000_001
        )
    }

    func testBundledCSVKeepsCursorRatesSeparateFromDirectAPIPrices() throws {
        let pricing = TestPricing.bundled
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        2026-10-28T00:00:00Z,grok-4.5,100000,100000,100000,100000
        2026-10-28T00:00:00Z,gemini-3.5-flash-high,100000,100000,100000,100000
        2026-10-28T00:00:00Z,gemini-3.6-flash,100000,100000,100000,100000
        2026-10-28T00:00:00Z,glm-5.3-flash-high,100000,100000,100000,100000
        """
        let expected = [
            (model: "grok-4.5", cursor: 1.05, api: 1.03),
            (model: "gemini-3.5-flash-high", cursor: 1.215, api: 0.5325),
            (model: "gemini-3.6-flash", cursor: 1.065, api: 0.5325),
            (model: "glm-5.3-flash-high", cursor: 0.0829, api: 0.083)
        ]

        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: pricing)

        XCTAssertEqual(parsed.rejectedRowCount, 0)
        XCTAssertEqual(parsed.rows.count, expected.count)
        for (row, value) in zip(parsed.rows, expected) {
            XCTAssertEqual(row.model, value.model)
            XCTAssertEqual(try XCTUnwrap(row.imputedCostDollars), value.cursor, accuracy: 0.000_001, row.model)
            XCTAssertEqual(
                try XCTUnwrap(pricing.estimatedCostDollars(
                    model: row.model, tokens: row.tokens, applyLongContextRates: false
                )),
                value.api,
                accuracy: 0.000_001,
                row.model
            )
        }
    }

    func testCursorModelDetailsKeepSeparateFamiliesAndHidePricingScope() throws {
        let pricing = TestPricing.bundled
        let csv = """
        Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens
        2026-10-28T12:00:00Z,gemini-3.5-flash-high,0,0,0,100000
        2026-10-28T12:00:00Z,gemini-3.6-flash-low,0,0,0,100000
        2026-10-28T12:00:00Z,gemini-3.7-flash-high,0,0,0,100000
        2026-10-28T12:00:00Z,gemini-3.8-flash-low,0,0,0,100000
        2026-10-28T12:00:00Z,grok-4.7-high-fast,0,0,0,100000
        2026-10-28T12:00:00Z,grok-4.7-low,0,0,0,100000
        """
        let parsed = try CursorUsageCSV.parse(csv: csv, pricing: pricing)
        let now = try XCTUnwrap(parsed.rows.first?.date)
        var lines: [MetricLine] = []

        let history = CursorUsageMapper.appendSpendLines(rows: parsed.rows, now: now, pricing: pricing, to: &lines)

        let models = try XCTUnwrap(history.modelUsage?.daily.first?.models)
        let expectedFamilies: Set<String> = [
            "gemini-3.5-flash", "gemini-3.6-flash", "gemini-3.7-flash", "gemini-3.8-flash", "grok-4.7"
        ]
        XCTAssertEqual(Set(models.map(\.model)), expectedFamilies)
        let gemini35 = try XCTUnwrap(models.first { $0.model == "gemini-3.5-flash" })
        XCTAssertEqual(try XCTUnwrap(gemini35.costUSD), 0.9, accuracy: 0.000_001)
        XCTAssertEqual(gemini35.variants?.map(\.model), ["gemini-3.5-flash-high"])
        let gemini36 = try XCTUnwrap(models.first { $0.model == "gemini-3.6-flash" })
        XCTAssertEqual(try XCTUnwrap(gemini36.costUSD), 0.75, accuracy: 0.000_001)
        XCTAssertEqual(gemini36.variants?.map(\.model), ["gemini-3.6-flash-low"])
        for (family, variant) in [
            ("gemini-3.7-flash", "gemini-3.7-flash-high"),
            ("gemini-3.8-flash", "gemini-3.8-flash-low")
        ] {
            let entry = try XCTUnwrap(models.first { $0.model == family })
            XCTAssertEqual(entry.totalTokens, 100_000)
            XCTAssertEqual(try XCTUnwrap(entry.costUSD), 0.375, accuracy: 0.000_001)
            XCTAssertEqual(entry.variants?.map(\.model), [variant])
        }
        let grok = try XCTUnwrap(models.first { $0.model == "grok-4.7" })
        XCTAssertEqual(grok.totalTokens, 200_000)
        XCTAssertEqual(try XCTUnwrap(grok.costUSD), 1.8, accuracy: 0.000_001)
        XCTAssertEqual(Set(try XCTUnwrap(grok.variants).map(\.model)), ["grok-4.7-high-fast", "grok-4.7-low"])
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("Expected today's spend details")
        }
        XCTAssertEqual(
            Set(try XCTUnwrap(breakdown).models.map(\.model)),
            expectedFamilies
        )
    }

    private func rates(input: Double, cacheRead: Double, output: Double, fast: Double = 1) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: input,
            cacheReadPerMillion: cacheRead,
            fastMultiplier: fast
        )
    }

    private func makePricing(
        supplement: [String: ModelRates] = [:],
        primary: [String: ModelRates] = [:]
    ) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(pricing: supplement),
            primary: PricingCatalog(entries: primary),
            secondary: PricingCatalog()
        )
    }

    private func makePricing(
        supplement: [String: ModelRates] = [:],
        aliases: [(String, String)],
        primary: [String: ModelRates] = [:]
    ) throws -> ModelPricing {
        let rules = try aliases.map { pattern, canonical in
            PricingSupplement.AliasRule(pattern: try NSRegularExpression(pattern: pattern), canonical: canonical)
        }
        return ModelPricing(
            supplement: PricingSupplement(pricing: supplement, aliasRules: rules),
            primary: PricingCatalog(entries: primary),
            secondary: PricingCatalog()
        )
    }
}
