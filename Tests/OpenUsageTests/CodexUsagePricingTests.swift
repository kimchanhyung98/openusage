import XCTest
@testable import OpenUsage

final class CodexUsagePricingTests: XCTestCase {
    private let pricing = TestPricing.bundled
    private let date = Date(timeIntervalSince1970: 1_789_200_000)

    func testBundledStandardRequestsMatchNativeAndPi() throws {
        let cases: [(String, Double)] = [
            ("gpt-5.6-sol", 1.98), ("gpt-6-astra", 4.95),
            ("gpt-5.6-terra", 1.02), ("gpt-5.6-luna", 0.102),
            ("gpt-daybreak-blue-latest", 1.98)
        ]
        for (model, expected) in cases {
            let native = CodexLogUsageScanner.aggregate(events: [
                .init(timestamp: date, model: model, input: 300_000, cached: 100_000,
                      output: 10_000, reasoning: 0, total: 310_000)
            ], since: .distantPast, pricing: pricing)
            let pi = PiUsageScanner.aggregate(entries: [
                .init(timestamp: date, cardID: "codex", model: model, carriedCost: 0,
                      tokens: .init(input: 200_000, cacheRead: 100_000, output: 10_000),
                      reportedTotalTokens: 310_000)
            ], cardID: "codex", since: .distantPast, pricing: pricing,
               costEstimator: CodexUsagePricing.estimatePi)
            XCTAssertEqual(try XCTUnwrap(native.series.daily.first?.costUSD), expected, accuracy: 1e-9, model)
            XCTAssertEqual(pi.series, native.series, model)
            XCTAssertEqual(pi.modelUsage, native.modelUsage, model)
            XCTAssertEqual(pi.unknownModelsByDay, native.unknownModelsByDay, model)
        }
    }

    func testLongContextThresholdIncludesReadAndWriteButNotOutput() throws {
        let cases: [(TokenBreakdown, Double)] = [
            (.init(input: 200_000, cacheRead: 72_000, output: 1_000), 0.8488),
            (.init(input: 200_001, cacheRead: 72_000, output: 1_000), 1.687608),
            (.init(input: 200_000, cacheWrite5m: 72_000, output: 1_000), 1.18),
            (.init(input: 200_001, cacheWrite5m: 72_000, output: 1_000), 2.350008),
            (.init(input: 1, output: 300_000), 6.000004)
        ]
        for (tokens, expected) in cases {
            XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                model: "gpt-5.6-sol", tokens: tokens, pricing: pricing
            )), expected, accuracy: 1e-9)
        }
        let astra = try XCTUnwrap(pricing.resolve(model: "gpt-6-astra"))
        let adjusted = CodexUsagePricing.adjusted(rates: astra, model: "gpt-6-astra")
        XCTAssertEqual(adjusted.costDollars(for: .init(input: 272_000)), 2.72, accuracy: 1e-9)
        XCTAssertEqual(adjusted.costDollars(for: .init(input: 272_001)), 5.44002, accuracy: 1e-9)
        XCTAssertEqual(adjusted.costDollars(for: .init(input: 200_000, cacheWrite5m: 100_000)), 6.5, accuracy: 1e-9)
    }

    func testAstraPriorityAndFastAliasApplyOneCodexMultiplier() throws {
        let tokens = TokenBreakdown(input: 200_000, cacheRead: 100_000, output: 10_000, isFast: true)
        for model in ["gpt-6-astra", "gpt-6-astra-high-fast", "openai/gpt-6-astra-fast-20260901"] {
            XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                model: model, tokens: tokens, pricing: pricing
            )), 9.9, accuracy: 1e-9, model)
        }
    }

    func testFastOnlyEntryIsNotMultipliedAgain() throws {
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: [
                "custom-fast": .init(inputPerMillion: 7, outputPerMillion: 21,
                                     cacheWritePerMillion: 7, cacheReadPerMillion: 1)
            ]), primary: PricingCatalog(), secondary: PricingCatalog()
        )
        XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
            model: "custom-fast", tokens: .init(input: 1_000, isFast: true), pricing: pricing
        )), 0.007, accuracy: 1e-9)
    }

    func testAlternateTerminalFastSeparatorsApplyOneCodexMultiplier() throws {
        for model in ["gpt-5.5", "gpt-6-astra-high"] {
            let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: model + "-fast", tokens: .init(input: 300_000), pricing: pricing))
            for suffix in [".fast", "@fast"] {
                for priority in [false, true] {
                    let actual = try XCTUnwrap(CodexUsagePricing.estimate(model: model + suffix, tokens: .init(input: 300_000, isFast: priority), pricing: pricing))
                    XCTAssertEqual(actual, expected, accuracy: 1e-9)
                }
                let rates = ModelRates(inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)
                let snapshot = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: ["custom" + suffix: rates]), secondary: PricingCatalog())
                XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(model: "custom" + suffix, tokens: .init(input: 1_000, isFast: true), pricing: snapshot)), 0.007, accuracy: 1e-9)
            }
        }
    }

    func testUnprefixedDatedExactRatesPrecedeCanonicalFallback() throws {
        let rates = ModelRates(inputPerMillion: 7, outputPerMillion: 14, cacheWritePerMillion: 7, cacheReadPerMillion: 7)
        for base in ["gpt-6-astra", "gpt-6-astra-high", "gpt-5.6-sol-high"] {
            for date in ["-20260901", "-2026-09-01"] {
                for secondary in [false, true] {
                    let catalog = PricingCatalog(entries: [base + date: rates])
                    let snapshot = ModelPricing(supplement: pricing.supplement, primary: secondary ? PricingCatalog() : catalog, secondary: secondary ? catalog : PricingCatalog())
                    for priority in [false, true] {
                        let cost = try XCTUnwrap(CodexUsagePricing.estimate(model: base + date, tokens: .init(input: 300_000, isFast: priority), pricing: snapshot))
                        XCTAssertEqual(cost, priority ? 8.4 : 4.2, accuracy: 1e-9)
                        for separator in ["-", ".", "@"] {
                            let fastCost = try XCTUnwrap(CodexUsagePricing.estimate(model: base + separator + "fast" + date, tokens: .init(input: 300_000, isFast: priority), pricing: snapshot))
                            XCTAssertEqual(fastCost, 8.4, accuracy: 1e-9)
                        }
                    }
                }
            }
        }
    }

    func testDatedAlternateFastSeparatorsKeepCodexRequestRates() throws {
        for base in ["gpt-5.5", "gpt-5.6-sol-high", "gpt-6-astra-high"] {
            for prefix in ["", "openai/"] {
                for date in ["-20260901", "-2026-09-01"] {
                    for priority in [false, true] {
                        let tokens = TokenBreakdown(input: 300_000, cacheRead: 20_000, output: 1_000, isFast: priority)
                        let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: prefix + base + "-fast" + date, tokens: tokens, pricing: pricing))
                        for separator in [".", "@"] {
                            let model = prefix + base + separator + "fast" + date
                            let actual = try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: tokens, pricing: pricing), model)
                            XCTAssertEqual(actual, expected, accuracy: 1e-9, model)
                        }
                    }
                }
            }
        }
    }

    func testPrimaryFastOnlyEntryIsNotUsedAsStandardBase() throws {
        let rates = ModelRates(inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)
        let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: ["custom-fast": rates]), secondary: PricingCatalog())
        XCTAssertNil(pricing.resolve(model: "custom"))
        XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(model: "custom-fast", tokens: .init(input: 1_000, isFast: true), pricing: pricing)), 0.007, accuracy: 1e-9)
    }

    func testProviderPrefixedAndDatedModelsKeepCodexLongContextAndPriorityRules() throws {
        let rates = ModelRates(inputPerMillion: 4, outputPerMillion: 20, cacheWritePerMillion: 5, cacheReadPerMillion: 0.4)
        for base in ["gpt-5.6-sol", "gpt-5.5", "gpt-5.4-pro"] {
            let pricing = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: [base: rates]), secondary: PricingCatalog())
            for fast in [false, true] {
                let tokens = TokenBreakdown(input: 200_000, cacheRead: 100_000, output: 10_000, isFast: fast)
                let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: base, tokens: tokens, pricing: pricing))
                for model in ["openai/\(base)", "openai/\(base)-20260901"] {
                    XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: tokens, pricing: pricing)), expected, accuracy: 1e-9, model)
                }
            }
        }
    }

    func testMissingPiModelStillValidatesUnsupportedWriteRetention() {
        let entry = PiUsageScanner.Entry(timestamp: date, cardID: "codex", model: "", carriedCost: nil,
                                        tokens: .init(cacheWrite1h: 1_000), reportedTotalTokens: 1_000)
        let scan = PiUsageScanner.aggregate(entries: [entry], cardID: "codex", since: .distantPast, pricing: pricing, costEstimator: CodexUsagePricing.estimatePi)
        XCTAssertEqual(scan.unsupportedPricingRows, 1)
        XCTAssertNotNil(scan.pricingWarning)
        XCTAssertNil(scan.usageHistory)
    }

    func testBundledSupplementPricesProviderPrefixedCodexRequests() throws {
        for model in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            for fast in [false, true] {
                let tokens = TokenBreakdown(input: 200_000, cacheRead: 100_000, output: 10_000, isFast: fast)
                let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: tokens, pricing: pricing))
                XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(model: "openai/\(model)", tokens: tokens, pricing: pricing)), expected, accuracy: 1e-9)
            }
        }
    }

    func testProviderSpecificExactRatesStillPrecedeUnprefixedSupplement() throws {
        let low = ModelRates(inputPerMillion: 1, outputPerMillion: 2, cacheWritePerMillion: 1, cacheReadPerMillion: 1)
        let high = ModelRates(inputPerMillion: 7, outputPerMillion: 14, cacheWritePerMillion: 7, cacheReadPerMillion: 7)
        let pricing = ModelPricing(supplement: PricingSupplement(pricing: ["gpt-5.6-sol": low]),
                                   primary: PricingCatalog(entries: ["openai/gpt-5.6-sol": high]), secondary: PricingCatalog())
        XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(model: "openai/gpt-5.6-sol", tokens: .init(input: 1_000), pricing: pricing)), 0.007, accuracy: 1e-9)
    }

    func testFastSegmentsWithTrailingQualifiersCannotSupplyStandardRates() throws {
        let standard = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3, cacheReadPerMillion: 3)
        let fast = ModelRates(inputPerMillion: 0.2, outputPerMillion: 0.5, cacheWritePerMillion: 0.2, cacheReadPerMillion: 0.2)
        for suffix in ["-fast", "-fast-non-reasoning", "-fast@20260901", "-fast_preview", "-fast/non-reasoning"] {
            let key = "azure_ai/grok-4" + suffix
            let catalog = PricingCatalog(entries: ["azure_ai/grok-4": standard, key: fast])
            let pricing = ModelPricing(supplement: PricingSupplement(), primary: catalog, secondary: PricingCatalog())
            XCTAssertEqual(pricing.resolve(model: "grok-4"), standard, key)
            XCTAssertEqual(pricing.resolve(model: key), fast, "Exact variant rates must remain available")
        }
        let catalog = PricingCatalog(entries: ["vendor/custom-faster": standard, "vendor/custom-fast-non-reasoning": fast])
        XCTAssertEqual(catalog.findFuzzy("custom", excludingFastVariants: true)?.rates, standard)
    }

    func testGenuineFastNamedModelsRetainProviderFuzzyRates() throws {
        let model = "grok-code-fast-1-0825"
        let explicit = try XCTUnwrap(pricing.primary.findExact("xai/" + model)?.rates)
        XCTAssertEqual(pricing.resolve(model: model), explicit)
        let rates = ModelRates(inputPerMillion: 7, outputPerMillion: 14, cacheWritePerMillion: 7, cacheReadPerMillion: 7)
        for model in ["grok-code-fast-1-0825", "grok-4-fast-non-reasoning", "custom-fast@20260901"] {
            let snapshot = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: ["vendor/" + model: rates]), secondary: PricingCatalog())
            XCTAssertEqual(snapshot.resolve(model: model), rates, model)
        }
    }

    func testProviderExactAstraRatesPrecedeBundledAliasesForCodexOnly() throws {
        let rates = ModelRates(inputPerMillion: 7, outputPerMillion: 14, cacheWritePerMillion: 7, cacheReadPerMillion: 7)
        for secondary in [false, true] {
            let catalog = PricingCatalog(entries: ["openai/gpt-6-astra": rates, "openai/gpt-6-astra-high-20260901": rates])
            let snapshot = ModelPricing(supplement: pricing.supplement,
                primary: secondary ? PricingCatalog() : catalog, secondary: secondary ? catalog : PricingCatalog())
            for model in ["openai/gpt-6-astra", "openai/gpt-6-astra-high-20260901"] {
                XCTAssertEqual(snapshot.resolve(model: model), pricing.resolve(model: "gpt-6-astra"), "Generic alias precedence stays unchanged")
                for fast in [false, true] {
                    let cost = try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: .init(input: 1_000, isFast: fast), pricing: snapshot))
                    XCTAssertEqual(cost, fast ? 0.014 : 0.007, accuracy: 1e-9, model)
                }
            }
            for model in ["openai/gpt-6-astra-fast", "openai/gpt-6-astra-high-fast-20260901"] {
                for fast in [false, true] {
                    let cost = try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: .init(input: 300_000, isFast: fast), pricing: snapshot))
                    XCTAssertEqual(cost, 8.4, accuracy: 1e-9, model)
                }
            }
        }
    }

    func testBundledDatedSupplementModelsRetainCodexRequestRates() throws {
        for base in ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"] {
            for suffix in ["-20260901", "-2026-09-01"] {
                for prefix in ["", "openai/"] {
                    for fast in [false, true] {
                        let tokens = TokenBreakdown(input: 300_000, cacheRead: 20_000, output: 1_000, isFast: fast)
                        let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: base, tokens: tokens, pricing: pricing))
                        XCTAssertEqual(try XCTUnwrap(CodexUsagePricing.estimate(
                            model: prefix + base + suffix, tokens: tokens, pricing: pricing
                        )), expected, accuracy: 1e-9)
                    }
                }
            }
        }
        for suffix in ["-2", "-202609", "-preview"] {
            XCTAssertNil(CodexUsagePricing.estimate(model: "openai/gpt-5.6-sol" + suffix, tokens: .init(input: 1_000), pricing: pricing))
        }
    }

    func testQualifiedFastAliasesPreserveExactProviderBaseRates() throws {
        let qualified = ModelRates(inputPerMillion: 7, outputPerMillion: 14, cacheWritePerMillion: 7, cacheReadPerMillion: 7)
        let generic = ModelRates(inputPerMillion: 3, outputPerMillion: 6, cacheWritePerMillion: 3, cacheReadPerMillion: 3)
        for qualifier in ["-high", "-20260901", "-high-20260901", "-high-2026-09-01"] {
            let base = "openai/gpt-6-astra" + qualifier
            let fast = qualifier.hasPrefix("-high")
                ? "openai/gpt-6-astra-high-fast" + qualifier.dropFirst("-high".count)
                : "openai/gpt-6-astra-fast" + qualifier
            for secondary in [false, true] {
                let catalog = PricingCatalog(entries: [base: qualified, "openai/gpt-6-astra": generic])
                let snapshot = ModelPricing(supplement: pricing.supplement,
                    primary: secondary ? PricingCatalog() : catalog, secondary: secondary ? catalog : PricingCatalog())
                for priority in [false, true] {
                    let cost = try XCTUnwrap(CodexUsagePricing.estimate(
                        model: fast, tokens: .init(input: 300_000, isFast: priority), pricing: snapshot
                    ))
                    XCTAssertEqual(cost, 8.4, accuracy: 1e-9, fast)
                }
            }
        }
    }

    func testNormalizedFastSeparatorsKeepDistinctRates() {
        let standard = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3, cacheReadPerMillion: 3)
        let fast = ModelRates(inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 7)
        for separator in ["-", ".", "@"] {
            let catalog = PricingCatalog(entries: ["vendor/grok-4": standard, "vendor/grok-4" + separator + "fast-non-reasoning": fast])
            let snapshot = ModelPricing(supplement: PricingSupplement(), primary: catalog, secondary: PricingCatalog())
            XCTAssertEqual(snapshot.resolve(model: "grok-4"), standard)
            for querySeparator in ["-", ".", "@"] {
                XCTAssertEqual(snapshot.resolve(model: "grok-4" + querySeparator + "fast-non-reasoning"), fast)
            }
        }
    }

    func testQualifiedEffortModelsRetainCodexTierRules() throws {
        for (base, effort) in [("gpt-5.6-sol", "high"), ("gpt-5.6-terra", "max"),
                               ("gpt-5.5", "extra-high"), ("gpt-6-astra", "max")] {
            for prefix in ["", "openai/"] {
                for suffix in ["", "-20260901", "-2026-09-01"] {
                    for priority in [false, true] {
                        let tokens = TokenBreakdown(input: 300_000, cacheRead: 20_000, output: 1_000, isFast: priority)
                        let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: base, tokens: tokens, pricing: pricing))
                        let actual = try XCTUnwrap(CodexUsagePricing.estimate(model: prefix + base + "-" + effort + suffix, tokens: tokens, pricing: pricing))
                        XCTAssertEqual(actual, expected, accuracy: 1e-9)
                        var priorityTokens = tokens
                        priorityTokens.isFast = true
                        let fastExpected = try XCTUnwrap(CodexUsagePricing.estimate(model: base, tokens: priorityTokens, pricing: pricing))
                        let fastActual = try XCTUnwrap(CodexUsagePricing.estimate(
                            model: prefix + base + "-" + effort + "-fast" + suffix, tokens: tokens, pricing: pricing
                        ))
                        XCTAssertEqual(fastActual, fastExpected, accuracy: 1e-9)
                    }
                }
            }
        }
    }

    func testNativeReasoningIsAlreadyIncludedInOutputCost() throws {
        let text = CodexLogFixture.tokenCount(timestamp: "2026-09-12T10:00:00Z",
            last: CodexLogFixture.usage(input: 100, output: 10, reasoning: 5), model: "gpt-5.6-sol")
        let events = CodexLogUsageScanner.parseFile(Data(text.utf8))
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing)
        let expected = try XCTUnwrap(CodexUsagePricing.estimate(model: "gpt-5.6-sol", tokens: .init(input: 100, output: 10), pricing: pricing))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 110)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), expected, accuracy: 1e-9)
    }

    func testAutomaticReviewKeepsIdentityWhileUsingRequestPricingForItsReference() throws {
        let event = CodexLogUsageScanner.Event(timestamp: date, model: "codex-auto-review", input: 300_000,
            cached: 100_000, output: 10_000, reasoning: 0, total: 310_000, isFast: true, pricingModel: "gpt-5.6-sol")
        let scan = CodexLogUsageScanner.aggregate(events: [event], since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 3.96, accuracy: 1e-9)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, "codex-auto-review")
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }

    func testNewPricingSnapshotRepricesLongRequestsWithoutReparsing() throws {
        let tokens = TokenBreakdown(input: 300_000, output: 10_000)
        func snapshot(_ rate: Double) -> ModelPricing {
            ModelPricing(supplement: PricingSupplement(pricing: [
                "gpt-5.6-sol": .init(inputPerMillion: rate, outputPerMillion: rate * 5,
                                    cacheWritePerMillion: rate * 1.25, cacheReadPerMillion: rate * 0.1)
            ]), primary: PricingCatalog(), secondary: PricingCatalog())
        }
        let first = try XCTUnwrap(CodexUsagePricing.estimate(model: "gpt-5.6-sol", tokens: tokens, pricing: snapshot(4)))
        let next = try XCTUnwrap(CodexUsagePricing.estimate(model: "gpt-5.6-sol", tokens: tokens, pricing: snapshot(8)))
        XCTAssertEqual(next, first * 2, accuracy: 1e-9)
    }

    func testUnsupportedPiWriteRetentionWarnsInsteadOfUsingAnthropicRates() {
        let entry = PiUsageScanner.Entry(
            timestamp: date, cardID: "codex", model: "gpt-5.6-sol", carriedCost: nil,
            tokens: .init(cacheWrite1h: 1_000), reportedTotalTokens: 1_000
        )
        let scan = PiUsageScanner.aggregate(
            entries: [entry], cardID: "codex", since: .distantPast, pricing: pricing,
            costEstimator: CodexUsagePricing.estimatePi
        )
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.unsupportedPricingRows, 1)
        XCTAssertNotNil(scan.pricingWarning)
        XCTAssertNil(scan.usageHistory)
        XCTAssertEqual(scan.unknownModelsByDay.values.first, ["gpt-5.6-sol"])
        var carried = entry
        carried.carriedCost = 7
        let priced = PiUsageScanner.aggregate(
            entries: [carried], cardID: "codex", since: .distantPast, pricing: pricing,
            costEstimator: CodexUsagePricing.estimatePi
        )
        XCTAssertEqual(priced.series.daily.first?.costUSD, 7)
        XCTAssertEqual(priced.unsupportedPricingRows, 0)
        XCTAssertNil(priced.pricingWarning)
    }

    func testPiGenericEstimatorAndCardIsolationRemainUnchanged() throws {
        let entry = PiUsageScanner.Entry(
            timestamp: date, cardID: "claude", model: "gpt-5.6-sol", carriedCost: nil,
            tokens: .init(input: 300_000, output: 10_000), reportedTotalTokens: 310_000
        )
        let generic = PiUsageScanner.aggregate(entries: [entry], cardID: "claude", since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(generic.series.daily.first?.costUSD), 1.4, accuracy: 1e-9)
        let otherCard = PiUsageScanner.aggregate(
            entries: [entry], cardID: "codex", since: .distantPast, pricing: pricing,
            costEstimator: CodexUsagePricing.estimatePi
        )
        XCTAssertTrue(otherCard.series.daily.isEmpty)
        XCTAssertNil(otherCard.pricingWarning)
    }

    @MainActor
    func testUnsupportedPricingPreservesMergedWarningAndLastGoodHistory() async throws {
        let native = CodexLogUsageScanner.aggregate(events: [
            .init(timestamp: date, model: "gpt-5.6-sol", input: 1_000, cached: 0,
                  output: 0, reasoning: 0, total: 1_000)
        ], since: .distantPast, pricing: pricing)
        let unsupported = PiUsageScanner.aggregate(entries: [
            .init(timestamp: date, cardID: "codex", model: "gpt-5.6-sol", carriedCost: nil,
                  tokens: .init(cacheWrite1h: 1_000), reportedTotalTokens: 1_000)
        ], cardID: "codex", since: .distantPast, pricing: pricing,
           costEstimator: CodexUsagePricing.estimatePi)
        let mixed = try XCTUnwrap(DailyUsageAccumulator.merged([native, unsupported]))
        XCTAssertEqual(mixed.series, native.series)
        XCTAssertEqual(mixed.unsupportedPricingRows, 1)
        XCTAssertNotNil(mixed.pricingWarning)
        XCTAssertNotNil(mixed.usageHistory)
        let rejected = try XCTUnwrap(DailyUsageAccumulator.merged([nil, unsupported]))
        XCTAssertNil(rejected.usageHistory)
        XCTAssertNotNil(rejected.pricingWarning)

        let codex = CodexProvider()
        let provider = codex.provider
        let runtime = TogglingProviderRuntime(
            provider: provider, descriptors: codex.widgetDescriptors,
            first: .init(providerID: provider.id, displayName: provider.displayName, lines: [],
                         refreshedAt: date, usageHistory: native.usageHistory),
            second: .init(providerID: provider.id, displayName: provider.displayName,
                          lines: [.progress(label: "Session", used: 42, limit: 100, format: .percent)],
                          refreshedAt: date, usageHistory: rejected.usageHistory, warning: rejected.pricingWarning)
        )
        let suite = "CodexUnsupportedPricingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = date
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: codex.widgetDescriptors),
            providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults, now: { now }
        )
        await store.refreshAll(force: true)
        await store.refreshAll(force: true)
        XCTAssertEqual(store.snapshots[provider.id]?.usageHistory, native.usageHistory)
        XCTAssertEqual(store.warningMessage(for: provider.id), rejected.pricingWarning)
        XCTAssertNotNil(store.snapshots[provider.id]?.line(label: "Session"))
    }

    func testPiScanPassesEstimatorToCachedAggregation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = #"{"type":"message","timestamp":"2026-09-12T00:00:00Z","message":{"role":"assistant","provider":"openai-codex","model":"gpt-5.6-sol","usage":{"input":300000,"output":10000,"totalTokens":310000,"cost":{"total":0}}}}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("session.jsonl"))
        let scanner = PiUsageScanner(
            environment: FakeEnvironment(["PI_CODING_AGENT_SESSION_DIR": directory.path]),
            incrementalScanner: IncrementalJSONLScanner<PiUsageScanner.Entry>(logTag: LogTag.plugin("pi"))
        )
        let now = try XCTUnwrap(OpenUsageISO8601.date(from: "2026-09-13T00:00:00Z"))
        let generic = await scanner.scan(cardID: "codex", now: now, pricing: pricing)
        let codex = await scanner.scan(cardID: "codex", now: now, pricing: pricing, costEstimator: CodexUsagePricing.estimatePi)
        XCTAssertEqual(try XCTUnwrap(generic?.series.daily.first?.costUSD), 1.4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(codex?.series.daily.first?.costUSD), 2.7, accuracy: 1e-9)
    }
}
