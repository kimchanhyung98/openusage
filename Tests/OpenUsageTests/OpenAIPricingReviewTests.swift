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

    private func event(model: String) throws -> CodexLogUsageScanner.Event {
        CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-30T00:00:00Z")),
            model: model, input: 1_000, cached: 0, output: 100, reasoning: 0, total: 1_100)
    }
}
