import XCTest

@testable import OpenUsage

final class OpenAIPricingTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testNewModelsUsePublishedStandardRates() throws {
        let cases: [(String, Double, Double, Double, Double)] = [
            ("gpt-6.1-sol", 2, 2.5, 0.1, 10),
            ("gpt-6-sol", 2, 2.5, 0.2, 10),
            ("gpt-6-luna", 0.1, 0.125, 0.01, 0.5),
            ("gpt-6-astra-ultrafast", 60, 75, 6, 300),
            ("gpt-5.5-cyber", 12.5, 12.5, 1.25, 75),
            ("chat-latest", 5, 5, 0.5, 30),
        ]
        for (model, input, write, read, output) in cases {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, input, model)
            XCTAssertEqual(rates.cacheWritePerMillion, write, model)
            XCTAssertEqual(rates.cacheReadPerMillion, read, model)
            XCTAssertEqual(rates.outputPerMillion, output, model)
        }
    }

    func testNewModelAliasesPreserveRatesAndSpeed() throws {
        for model in ["gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna"] {
            let base = try XCTUnwrap(pricing.resolve(model: model))
            for prefix in ["", "openai/"] {
                for date in ["", "-20260929", "-2026-09-29"] {
                    let name = prefix + model + "-max"
                    XCTAssertEqual(pricing.resolve(model: name + date), base)
                    for separator in ["-", ".", "@"] {
                        XCTAssertEqual(pricing.resolve(model: name + separator + "fast" + date), base.scaled(by: 2))
                    }
                }
            }
        }
        XCTAssertEqual(pricing.resolve(model: "openai/GPT-6.1-SOL-high"), pricing.resolve(model: "gpt-6.1-sol"))
        XCTAssertNil(pricing.resolve(model: "gpt-6.1-astra"))
        XCTAssertNil(pricing.resolve(model: "gpt-6.1-luna"))
    }

    func testGpt6SupportsNoneEffortWithoutInventingGpt61Aliases() throws {
        for model in ["gpt-6-sol", "gpt-6-luna"] {
            let rates = try XCTUnwrap(pricing.resolve(model: model))
            XCTAssertEqual(pricing.resolve(model: "openai/" + model + "-none-20260922"), rates)
            XCTAssertEqual(pricing.resolve(model: model + "-none-fast"), rates.scaled(by: 2))
        }
        XCTAssertNil(pricing.supplement.canonicalName(for: "gpt-6.1-sol-none"))
    }

    func testUltrafastKeepsExplicitQualifiedRates() throws {
        let rates = ModelRates(
            inputPerMillion: 7, outputPerMillion: 21, cacheWritePerMillion: 7, cacheReadPerMillion: 1)
        for name in ["openai/gpt-6-astra-ultrafast", "gpt-6-astra-high-ultrafast-20260929"] {
            for secondary in [false, true] {
                let catalog = PricingCatalog(entries: [name: rates])
                let snapshot = ModelPricing(
                    supplement: pricing.supplement,
                    primary: secondary ? PricingCatalog() : catalog,
                    secondary: secondary ? catalog : PricingCatalog())
                XCTAssertEqual(
                    try XCTUnwrap(
                        CodexUsagePricing.estimate(
                            model: name, tokens: .init(input: 300_000, isFast: true), pricing: snapshot
                        )), 4.2, accuracy: 1e-9, name)
                XCTAssertEqual(
                    try XCTUnwrap(
                        CodexUsagePricing.estimate(
                            model: name.replacingOccurrences(of: "-ultrafast", with: ""),
                            tokens: .init(input: 300_000), pricing: snapshot, isUltrafast: true
                        )), 4.2, accuracy: 1e-9, name)
                for separator in [".", "@"] {
                    XCTAssertEqual(
                        try XCTUnwrap(
                            CodexUsagePricing.estimate(
                                model: name.replacingOccurrences(of: "-ultrafast", with: separator + "ultrafast"),
                                tokens: .init(input: 300_000), pricing: snapshot
                            )), 4.2, accuracy: 1e-9, name)
                }
            }
        }
    }

    func testNewCodexModelsApplyLongContextAndFastOnce() throws {
        let cases: [(String, Double, Double)] = [
            ("gpt-6.1-sol", 0.4172, 0.829404),
            ("gpt-6-sol", 0.4244, 0.843804),
            ("gpt-6-luna", 0.02122, 0.0421902),
        ]
        for (model, boundaryCost, longCost) in cases {
            for fast in [false, true] {
                for suffix in ["", "-max", "-20260929"] {
                    let boundary = TokenBreakdown(input: 200_000, cacheRead: 72_000, output: 1_000, isFast: fast)
                    let long = TokenBreakdown(input: 200_001, cacheRead: 72_000, output: 1_000, isFast: fast)
                    let multiplier = fast ? 2.0 : 1.0
                    XCTAssertEqual(
                        try XCTUnwrap(
                            CodexUsagePricing.estimate(
                                model: model + suffix, tokens: boundary, pricing: pricing
                            )), boundaryCost * multiplier, accuracy: 1e-9)
                    XCTAssertEqual(
                        try XCTUnwrap(
                            CodexUsagePricing.estimate(
                                model: "openai/" + model + suffix, tokens: long, pricing: pricing
                            )), longCost * multiplier, accuracy: 1e-9)
                }
                XCTAssertEqual(
                    try XCTUnwrap(
                        CodexUsagePricing.estimate(
                            model: model + "-max-fast-20260929",
                            tokens: .init(input: 200_001, cacheRead: 72_000, output: 1_000, isFast: fast),
                            pricing: pricing
                        )), longCost * 2, accuracy: 1e-9)
            }
        }
        XCTAssertEqual(
            try XCTUnwrap(
                CodexUsagePricing.estimate(
                    model: "gpt-6.1-sol", tokens: .init(input: 200_001, cacheWrite5m: 72_000, output: 1_000),
                    pricing: pricing
                )), 1.175004, accuracy: 1e-9)
    }

    func testPublishedLegacyFastRatesApplyToAliasesAndRequestMetadata() throws {
        let cases: [(String, Double, Double, Double)] = [
            ("gpt-5.4-mini", 1.5, 0.15, 9),
            ("gpt-5.1", 2.5, 0.25, 20),
            ("gpt-5-mini", 0.45, 0.045, 3.6),
            ("gpt-4.1", 3.5, 0.875, 14),
            ("gpt-4.1-mini", 0.7, 0.175, 2.8),
            ("gpt-4.1-nano", 0.2, 0.05, 0.8),
            ("gpt-4o", 4.25, 2.125, 17),
            ("gpt-4o-2024-05-13", 8.75, 8.75, 26.25),
            ("gpt-4o-mini", 0.25, 0.125, 1),
        ]
        for (model, input, read, output) in cases {
            let rates = try XCTUnwrap(pricing.resolve(model: model + "-fast"), model)
            XCTAssertEqual(rates.inputPerMillion, input, accuracy: 1e-9, model)
            XCTAssertEqual(rates.cacheReadPerMillion, read, accuracy: 1e-9, model)
            XCTAssertEqual(rates.outputPerMillion, output, accuracy: 1e-9, model)
            XCTAssertEqual(
                try XCTUnwrap(
                    CodexUsagePricing.estimate(
                        model: model, tokens: .init(input: 1_000, cacheRead: 1_000, output: 1_000, isFast: true),
                        pricing: pricing
                    )), (input + read + output) / 1_000, accuracy: 1e-9, model)
        }
    }

    func testQualifiedFastModelsKeepTheirSpecificMultiplier() throws {
        let cases: [(String, Double, Double)] = [
            ("openai/gpt-5-mini-20260929", 1.8, 0.004095),
            ("openai/gpt-4.1-nano-20260929", 2, 0.00105),
            ("openai/gpt-4o-2024-05-13", 1.75, 0.04375),
        ]
        for (model, multiplier, expected) in cases {
            XCTAssertEqual(pricing.supplement.fastMultiplier(for: model), multiplier)
            XCTAssertEqual(
                try XCTUnwrap(
                    CodexUsagePricing.estimate(
                        model: model, tokens: .init(input: 1_000, cacheRead: 1_000, output: 1_000, isFast: true),
                        pricing: pricing
                    )), expected, accuracy: 1e-9, model)
        }
    }

    func testUltrafastAliasesUseTheirOwnRateWithoutFastMultiplier() throws {
        for alias in [
            "gpt-6-astra-ultrafast", "openai/gpt-6-astra-high-ultrafast-20260929",
            "gpt-6-astra.ultrafast", "gpt-6-astra@ultrafast",
        ] {
            for fast in [false, true] {
                XCTAssertEqual(
                    try XCTUnwrap(
                        CodexUsagePricing.estimate(
                            model: alias, tokens: .init(input: 272_000, output: 1_000, isFast: fast), pricing: pricing
                        )), 16.62, accuracy: 1e-9)
                XCTAssertEqual(
                    try XCTUnwrap(
                        CodexUsagePricing.estimate(
                            model: alias,
                            tokens: .init(
                                input: 200_001, cacheWrite5m: 50_000, cacheRead: 22_000, output: 1_000, isFast: fast),
                            pricing: pricing
                        )), 32.21412, accuracy: 1e-9)
            }
        }
    }

    func testUnpublishedUltrafastRatesNeverUseStandardFuzzyMatch() {
        let rates = ModelRates(
            inputPerMillion: 4, outputPerMillion: 20, cacheWritePerMillion: 5, cacheReadPerMillion: 0.4)
        let snapshot = ModelPricing(
            supplement: pricing.supplement,
            primary: PricingCatalog(entries: ["gpt-5.6-sol": rates]), secondary: PricingCatalog())
        for suffix in ["-ultrafast", ".ultrafast", "@ultrafast", "-ultrafast-20260929"] {
            XCTAssertNil(snapshot.resolve(model: "gpt-5.6-sol" + suffix))
            XCTAssertNil(
                CodexUsagePricing.estimate(
                    model: "gpt-5.6-sol" + suffix, tokens: .init(input: 1_000), pricing: snapshot
                ))
        }
        XCTAssertNil(
            CodexUsagePricing.estimate(
                model: "gpt-5.6-sol", tokens: .init(input: 1_000), pricing: snapshot, isUltrafast: true
            ))
        let ultrafastOnly = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["openai/custom-ultrafast-20260929": rates]),
            secondary: PricingCatalog())
        XCTAssertNil(ultrafastOnly.resolve(model: "custom"))
    }

    func testLoggedUltrafastTierTransitionsReachAggregation() throws {
        var lines = [CodexLogFixture.turnContext(timestamp: "2026-09-30T00:00:00Z", model: "gpt-6-astra")]
        for (index, tier) in ["ultrafast", "fast", "default"].enumerated() {
            lines.append(
                CodexLogFixture.threadSettingsApplied(
                    timestamp: "2026-09-30T00:00:0\(index)Z", serviceTier: tier
                ))
            lines.append(
                CodexLogFixture.tokenCount(
                    timestamp: "2026-09-30T00:01:0\(index)Z",
                    last: CodexLogFixture.usage(input: 1_000, output: 100)
                ))
        }
        let events = CodexLogUsageScanner.parseFile(Data(lines.joined(separator: "\n").utf8))
        XCTAssertEqual(events.map(\.isUltrafast), [true, false, false])
        XCTAssertEqual(events.map(\.isFast), [false, true, false])
        let restored = try JSONDecoder().decode([CodexLogUsageScanner.Event].self, from: JSONEncoder().encode(events))
        XCTAssertEqual(restored, events)
        let result = CodexLogUsageScanner.aggregate(events: restored, since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(result.series.daily.first?.costUSD), 0.135, accuracy: 1e-9)
        XCTAssertTrue(result.unknownModelsByDay.isEmpty)
        var unpublished = try XCTUnwrap(events.first)
        unpublished.model = "gpt-5.6-sol"
        let unknown = CodexLogUsageScanner.aggregate(events: [unpublished], since: .distantPast, pricing: pricing)
        XCTAssertEqual(unknown.unknownModelsByDay.values.first, ["gpt-5.6-sol (Ultrafast)"])
        XCTAssertTrue(unknown.series.daily.isEmpty)
    }

    func testVersionTenCacheReparsesUltrafastTier() async throws {
        let timestamp = "2026-09-30T00:00:00Z"
        let content = [
            CodexLogFixture.turnContext(timestamp: timestamp, model: "gpt-6-astra"),
            CodexLogFixture.threadSettingsApplied(timestamp: timestamp, serviceTier: "ultrafast"),
            CodexLogFixture.tokenCount(timestamp: timestamp, last: CodexLogFixture.usage(input: 1_000, output: 100)),
        ].joined(separator: "\n")
        let home = try CodexLogFixture.makeHome(files: ["sessions/ultrafast.jsonl": content])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let directory = home.appendingPathComponent("cache")
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence:
                .init(namespace: "codex", schemaVersion: 10, directory: directory, writeDebounce: .milliseconds(1)))
        let oldEvent = CodexLogUsageScanner.Event(
            timestamp: try XCTUnwrap(OpenUsageISO8601.date(from: timestamp)), model: "gpt-6-astra",
            input: 1_000, cached: 0, output: 100, reasoning: 0, total: 1_100
        )
        _ = await old.items(from: files, since: .distantPast, cacheIdentity: "ultrafast") { _ in [oldEvent] }
        await old.waitForPendingWritesForTesting()
        let scanner = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence:
                .init(namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion, directory: directory))
        let parsed = await scanner.items(
            from: files, since: .distantPast, cacheIdentity: "ultrafast", parse: CodexLogUsageScanner.parseFile
        )
        let events = try XCTUnwrap(parsed)
        XCTAssertEqual(events.map(\.isUltrafast), [true])
        let result = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing)
        XCTAssertEqual(try XCTUnwrap(result.series.daily.first?.costUSD), 0.09, accuracy: 1e-9)
        await scanner.waitForPendingWritesForTesting()
    }
}
