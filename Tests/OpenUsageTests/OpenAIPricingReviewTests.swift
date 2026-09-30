import XCTest

@testable import OpenUsage

final class OpenAIPricingReviewTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testDatedGpt41FastAliasesApplyPublishedMultiplier() throws {
        for prefix in ["", "openai/"] {
            for separator in ["-", ".", "@"] {
                for date in ["-20260929", "-2026-09-29"] {
                    let model = prefix + "gpt-4.1" + separator + "fast" + date
                    XCTAssertEqual(
                        try XCTUnwrap(pricing.estimatedCostDollars(model: model, tokens: .init(input: 1_000))),
                        0.0035, accuracy: 1e-9, model)
                    for fast in [false, true] {
                        XCTAssertEqual(
                            try XCTUnwrap(
                                CodexUsagePricing.estimate(
                                    model: model, tokens: .init(input: 1_000, isFast: fast), pricing: pricing
                                )),
                            0.0035, accuracy: 1e-9, model)
                    }
                }
            }
        }
    }

    func testDatedGpt54MiniEffortFastAliasesApplyPublishedMultiplier() throws {
        for prefix in ["", "openai/"] {
            for separator in ["-", ".", "@"] {
                for date in ["-20260929", "-2026-09-29"] {
                    let model = prefix + "gpt-5.4-mini-high" + separator + "fast" + date
                    XCTAssertEqual(
                        try XCTUnwrap(pricing.estimatedCostDollars(model: model, tokens: .init(input: 1_000))),
                        0.0015, accuracy: 1e-9, model)
                    for fast in [false, true] {
                        XCTAssertEqual(
                            try XCTUnwrap(
                                CodexUsagePricing.estimate(
                                    model: model, tokens: .init(input: 1_000, isFast: fast), pricing: pricing
                                )),
                            0.0015, accuracy: 1e-9, model)
                    }
                }
            }
        }
    }

    func testAggregationPreservesDistinctTiersAndDeduplicatesTheirCopies() throws {
        let standard = try event(model: "gpt-6-astra")
        var fast = standard
        fast.isFast = true
        var ultrafast = standard
        ultrafast.isUltrafast = true
        let events = [standard, fast, ultrafast, standard, fast, ultrafast]

        for ordered in [events, Array(events.reversed())] {
            let result = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)
            let day = try XCTUnwrap(result.series.daily.first)
            XCTAssertEqual(result.series.daily.count, 1)
            XCTAssertEqual(day.totalTokens, 3_300)
            XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.135, accuracy: 1e-9)
            XCTAssertTrue(result.unknownModelsByDay.isEmpty)
        }
    }

    func testUnknownUltrafastDoesNotDiscardStandardUsageOrItsWarning() throws {
        let standard = try event(model: "gpt-6-sol")
        var ultrafast = standard
        ultrafast.isUltrafast = true
        let events = [standard, ultrafast, standard, ultrafast]

        for ordered in [events, Array(events.reversed())] {
            let result = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)
            let day = try XCTUnwrap(result.series.daily.first)
            XCTAssertEqual(day.totalTokens, 1_100)
            XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.003, accuracy: 1e-9)
            XCTAssertEqual(result.unknownModelsByDay[day.date], ["gpt-6-sol (Ultrafast)"])
        }
    }

    func testUnpublishedUltrafastSegmentsNeverInheritStandardRates() {
        let rates = ModelRates(
            inputPerMillion: 4, outputPerMillion: 20, cacheWritePerMillion: 5, cacheReadPerMillion: 0.4,
            fastMultiplier: 2)
        let snapshot = ModelPricing(
            supplement: pricing.supplement,
            primary: PricingCatalog(entries: ["gpt-5.6-sol": rates]), secondary: PricingCatalog())

        for suffix in ["-ultrafast-high", ".ultrafast-high", "@ultrafast-high", "-ULTRAFAST", "-ultrafast-high-fast"] {
            let model = "gpt-5.6-sol" + suffix
            XCTAssertNil(snapshot.resolve(model: model), model)
            XCTAssertNil(
                CodexUsagePricing.estimate(model: model, tokens: .init(input: 1_000), pricing: snapshot), model)
        }
    }

    func testExplicitUltrafastEntriesRemainAvailableAcrossCatalogs() {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)

        for suffix in ["-ultrafast-high", "-ULTRAFAST", "-ultrafast-high-fast"] {
            let model = "custom" + suffix
            for secondary in [false, true] {
                let catalog = PricingCatalog(entries: [model: rates])
                let snapshot = ModelPricing(
                    supplement: PricingSupplement(),
                    primary: secondary ? PricingCatalog() : catalog,
                    secondary: secondary ? catalog : PricingCatalog())
                XCTAssertEqual(snapshot.resolve(model: model), rates, model)
            }
        }
    }

    func testDatedUltrafastSeparatorsResolveExplicitCatalogEntriesWithoutAliases() throws {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)

        for date in ["-20260929", "-2026-09-29"] {
            let catalog = PricingCatalog(entries: ["openai/custom-ultrafast" + date: rates])
            for secondary in [false, true] {
                let snapshot = ModelPricing(
                    supplement: PricingSupplement(),
                    primary: secondary ? PricingCatalog() : catalog,
                    secondary: secondary ? catalog : PricingCatalog())
                for separator in [".", "@"] {
                    let model = "openai/custom" + separator + "ultrafast" + date
                    XCTAssertEqual(snapshot.resolve(model: model), rates, model)
                    XCTAssertEqual(
                        try XCTUnwrap(snapshot.estimatedCostDollars(model: model, tokens: .init(input: 1_000))),
                        0.007, accuracy: 1e-9, model)
                }
            }
        }
    }

    func testDatedSpeedOnlyCatalogEntriesDoNotApplyFastMultiplierTwice() throws {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)

        for speed in ["fast", "ultrafast"] {
            for date in ["-20260929", "-2026-09-29"] {
                let catalog = PricingCatalog(entries: ["custom-" + speed + date: rates])
                for secondary in [false, true] {
                    let snapshot = ModelPricing(
                        supplement: PricingSupplement(),
                        primary: secondary ? PricingCatalog() : catalog,
                        secondary: secondary ? catalog : PricingCatalog())
                    for separator in ["-", ".", "@"] {
                        let model = "custom" + separator + speed + date
                        for fast in [false, true] {
                            XCTAssertEqual(
                                try XCTUnwrap(
                                    CodexUsagePricing.estimate(
                                        model: model, tokens: .init(input: 1_000, isFast: fast), pricing: snapshot
                                    )),
                                0.007, accuracy: 1e-9, model)
                        }
                    }
                }
            }
        }
    }

    func testDatedUltrafastAliasesFallBackToUndatedCatalogRates() throws {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)
        let catalog = PricingCatalog(entries: ["custom-ultrafast": rates])

        for secondary in [false, true] {
            let snapshot = ModelPricing(
                supplement: PricingSupplement(),
                primary: secondary ? PricingCatalog() : catalog,
                secondary: secondary ? catalog : PricingCatalog())
            for date in ["-20260929", "-2026-09-29"] {
                for separator in ["-", ".", "@"] {
                    let model = "custom" + separator + "ultrafast" + date
                    for fast in [false, true] {
                        XCTAssertEqual(
                            try XCTUnwrap(
                                CodexUsagePricing.estimate(
                                    model: model, tokens: .init(input: 1_000, isFast: fast), pricing: snapshot
                                )),
                            0.007, accuracy: 1e-9, model)
                    }
                }
            }
        }
    }

    func testMixedCaseSpeedCatalogEntriesCannotSupplyStandardFuzzyRates() {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)

        for speed in ["FAST", "Fast", "ULTRAFAST", "Ultrafast"] {
            for separator in ["-", ".", "@"] {
                let model = "custom" + separator + speed
                let catalog = PricingCatalog(entries: [model: rates])
                let snapshot = ModelPricing(
                    supplement: PricingSupplement(), primary: catalog, secondary: PricingCatalog())
                XCTAssertNil(catalog.findFuzzy("custom", excludingFastVariants: true), model)
                XCTAssertNil(snapshot.resolve(model: "custom"), model)
                XCTAssertEqual(snapshot.resolve(model: model), rates, model)
            }
        }
    }

    func testMixedCaseFastNamedModelsRetainProviderFuzzyRates() {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)

        for model in [
            "custom-FAST-non-reasoning", "custom.Fast-non-reasoning", "custom@Fast-non-reasoning",
            "custom-faster", "custom-ultrafaster",
        ] {
            let catalog = PricingCatalog(entries: ["vendor/" + model: rates])
            XCTAssertEqual(catalog.findFuzzy(model, excludingFastVariants: true)?.rates, rates, model)
        }
    }

    func testCodexCombinedUltrafastAndFastSlugsRemainUnpriced() {
        for prefix in ["", "openai/"] {
            for separator in ["-", ".", "@"] {
                for date in ["", "-20260929", "-2026-09-29"] {
                    let model = prefix + "gpt-6-astra" + separator + "ultrafast-fast" + date
                    XCTAssertNil(pricing.resolve(model: model), model)
                    for fast in [false, true] {
                        XCTAssertNil(
                            CodexUsagePricing.estimate(
                                model: model, tokens: .init(input: 1_000, isFast: fast), pricing: pricing), model)
                    }
                }
            }
        }
    }

    func testCodexPublishedAstraSpeedTiersKeepTheirRates() throws {
        for prefix in ["", "openai/"] {
            for date in ["", "-20260929", "-2026-09-29"] {
                for fast in [false, true] {
                    let tokens = TokenBreakdown(input: 1_000, isFast: fast)
                    for (suffix, expected) in [("", fast ? 0.02 : 0.01), ("-fast", 0.02), ("-ultrafast", 0.06)] {
                        let model = prefix + "gpt-6-astra" + suffix + date
                        XCTAssertEqual(
                            try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: tokens, pricing: pricing)),
                            expected, accuracy: 1e-9, model)
                    }
                }
            }
        }
    }

    func testMixedCaseFastSuffixesUsePublishedRatesWithoutChangingModelNames() throws {
        for prefix in ["", "openai/"] {
            for separator in ["-", ".", "@"] {
                for date in ["", "-20260929", "-2026-09-29"] {
                    for speed in ["FAST", "Fast"] {
                        let model = prefix + "gpt-4.1" + separator + speed + date
                        XCTAssertEqual(
                            try XCTUnwrap(pricing.estimatedCostDollars(model: model, tokens: .init(input: 1_000))),
                            0.0035, accuracy: 1e-9, model)
                        for fast in [false, true] {
                            XCTAssertEqual(
                                try XCTUnwrap(
                                    CodexUsagePricing.estimate(
                                        model: model, tokens: .init(input: 1_000, isFast: fast), pricing: pricing)),
                                0.0035, accuracy: 1e-9, model)
                        }
                    }
                }
            }
        }
        for model in ["custom-FAST-non-reasoning", "custom.FAST-preview", "CUSTOM-fastest"] {
            XCTAssertEqual(ModelPricing.normalizedFastName(model), model)
        }
        XCTAssertEqual(ModelPricing.normalizedFastName("Custom.FAST-20260929"), "Custom-fast-20260929")
    }

    func testUnregisteredFastBasesDoNotInheritNewExactMultipliersThroughFuzzyMatching() {
        for base in ["gpt-4o-vision-preview", "gpt-4o-minii", "gpt-4.1-custom"] {
            for prefix in ["", "openai/"] {
                for date in ["", "-20260929", "-2026-09-29"] {
                    let model = prefix + base + "-fast" + date
                    XCTAssertNil(pricing.resolve(model: model), model)
                }
            }
        }
    }

    func testExactMultiplierRestrictionsPreserveLegacyAndNativeFuzzyRates() throws {
        let rates = ModelRates(
            inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2, cacheReadPerMillion: 0.2)
        var nativeRates = rates
        nativeRates.fastMultiplier = 3
        let supplement = PricingSupplement(
            fastMultipliers: ["gpt-5": 2], exactFastMultipliers: ["gpt-5-mini": 1.8])

        for (entry, expected) in [(rates, 0.004), (nativeRates, 0.006)] {
            let snapshot = ModelPricing(
                supplement: supplement, primary: PricingCatalog(entries: ["gpt-5-mini": entry]),
                secondary: PricingCatalog())
            XCTAssertEqual(
                try XCTUnwrap(
                    snapshot.estimatedCostDollars(model: "gpt-5-mini-custom-fast", tokens: .init(input: 1_000))),
                expected, accuracy: 1e-9)
        }
    }

    func testMiniStandardAliasesMatchTheQualifiedCaseAndDateFormsOfFastAliases() {
        for prefix in ["", "openai/"] {
            for model in ["gpt-5.4-mini", "GPT-5.4-MINI"] {
                for effort in ["", "-high"] {
                    for date in ["", "-20260929", "-2026-09-29"] {
                        let standard = prefix + model + effort + date
                        let fast = prefix + model + effort + "-fast" + date
                        XCTAssertEqual(pricing.supplement.canonicalName(for: standard), "gpt-5.4-mini", standard)
                        XCTAssertEqual(pricing.supplement.canonicalName(for: fast), "gpt-5.4-mini-fast", fast)
                    }
                }
            }
        }
    }

    func testCursorMiniStandardAliasesShareOneModelBreakdownAndPreserveVariants() throws {
        let models = [
            "gpt-5.4-mini", "gpt-5.4-mini-high", "openai/gpt-5.4-mini-high-20260929",
            "GPT-5.4-MINI", "openai/GPT-5.4-MINI-high-2026-09-29",
        ]
        let csv =
            "Date,Model,Max Mode,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Cost\n"
            + models.map { "2026-09-30T00:00:00Z,\($0),No,0,1000000,0,0,Included" }.joined(separator: "\n")
        let rows = try CursorUsageCSV.parse(csv: csv, pricing: pricing).rows
        let now = try XCTUnwrap(rows.first?.date)
        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: pricing, to: &lines)

        XCTAssertEqual(rows.count, models.count)
        guard case .values(_, _, _, _, let unknownModels, let breakdown) = lines.first(where: { $0.label == "Today" })
        else {
            return XCTFail("Expected today's priced Mini usage")
        }
        XCTAssertTrue(unknownModels.isEmpty)
        let entries = try XCTUnwrap(breakdown?.models)
        XCTAssertEqual(entries.map(\.model), ["gpt-5.4-mini"])
        let mini = try XCTUnwrap(entries.first { $0.model == "gpt-5.4-mini" })
        XCTAssertEqual(mini.totalTokens, models.count * 1_000_000)
        XCTAssertEqual(try XCTUnwrap(mini.costUSD), Double(models.count) * 0.75, accuracy: 1e-9)
        XCTAssertEqual(Set(mini.variants?.map { $0.model.lowercased() } ?? []), Set(models.map { $0.lowercased() }))
    }

    private func event(model: String) throws -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-30T00:00:00Z")),
            model: model, input: 1_000, cached: 0, output: 100, reasoning: 0, total: 1_100)
    }
}
