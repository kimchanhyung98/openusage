import XCTest
@testable import OpenUsage

final class CodexUsagePricingAggregationTests: XCTestCase {
    func testRepeatedModelKeepsRequestFastAndLongContextRulesAcrossDays() throws {
        let pricing = snapshot(["gpt-6-sol": rates(2, fast: 3)])
        let requests = [
            event(0, model: "gpt-6-sol", input: 272_000, cached: 72_000, output: 1_000),
            event(1, model: "gpt-6-sol", input: 272_001, cached: 72_000, output: 1_000, isFast: true),
            event(2, model: "gpt-6-sol", day: 1, input: 272_000, cached: 72_000, output: 1_000, isFast: true),
            event(3, model: "gpt-6-sol", day: 1, input: 272_001, cached: 72_000, output: 1_000)
        ]
        let events = requests + [requests[1], requests[2]]

        for ordered in [events, Array(events.reversed())] {
            let scan = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)

            XCTAssertEqual(scan.series.daily.map(\.date), ["2026-09-13", "2026-09-12"])
            // 기본 요청 0.44, 장문 요청 0.878004. Fast 요청에만 3배 적용.
            try assertDay(scan, date: "2026-09-12", tokens: 546_001, cost: 3.074012,
                          models: ["gpt-6-sol": (546_001, 3.074012)])
            try assertDay(scan, date: "2026-09-13", tokens: 546_001, cost: 2.198004,
                          models: ["gpt-6-sol": (546_001, 2.198004)])
            XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        }
    }

    func testQualifiedAndDatedExactRatesStaySeparateInOneAggregation() throws {
        let alias = PricingSupplement.AliasRule(
            pattern: try NSRegularExpression(pattern: #"^(?:openai/)?gpt-6-astra(?:-20260901|-2026-09-01)?$"#),
            canonical: "gpt-6-astra"
        )
        let pricing = ModelPricing(
            supplement: PricingSupplement(pricing: ["gpt-6-astra": rates(2)], aliasRules: [alias]),
            primary: PricingCatalog(entries: [
                "openai/gpt-6-astra": rates(7),
                "gpt-6-astra-20260901": rates(11)
            ]),
            secondary: PricingCatalog(entries: ["openai/gpt-6-astra-2026-09-01": rates(13)])
        )
        let models = ["gpt-6-astra", "openai/gpt-6-astra", "gpt-6-astra-20260901",
                      "openai/gpt-6-astra-2026-09-01"]
        let events = (models + models).enumerated().map { event($0.offset, model: $0.element) }

        for ordered in [events, Array(events.reversed())] {
            let scan = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)

            XCTAssertEqual(scan.series.daily.count, 1)
            try assertDay(scan, date: "2026-09-12", tokens: 8_000, cost: 0.066, models: [
                "gpt-6-astra": (2_000, 0.004),
                "openai/gpt-6-astra": (2_000, 0.014),
                "gpt-6-astra-20260901": (2_000, 0.022),
                "openai/gpt-6-astra-2026-09-01": (2_000, 0.026)
            ])
            XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
        }
    }

    func testAutomaticReviewUsesEachPricingReferenceAndKeepsItsDisplayName() throws {
        let pricing = snapshot(["gpt-6-sol": rates(2), "gpt-6-luna": rates(5)])
        let events = [
            event(0, model: "codex-auto-review", pricingModel: "gpt-6-sol"),
            event(1, model: "codex-auto-review", input: 2_000, pricingModel: "gpt-6-luna"),
            event(2, model: "codex-auto-review", input: 3_000, pricingModel: "gpt-6-sol"),
            event(3, model: "codex-auto-review", day: 1, pricingModel: "unpublished-review-reference"),
            event(4, model: "codex-auto-review", day: 1, input: 2_000,
                  pricingModel: "unpublished-review-reference")
        ]

        for ordered in [events, Array(events.reversed())] {
            let scan = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)

            XCTAssertEqual(scan.series.daily.count, 1)
            XCTAssertEqual(scan.modelUsage?.daily.count, 1)
            try assertDay(scan, date: "2026-09-12", tokens: 6_000, cost: 0.018,
                          models: ["codex-auto-review": (6_000, 0.018)])
            XCTAssertEqual(scan.unknownModelsByDay, ["2026-09-13": ["codex-auto-review"]])
        }
    }

    func testRepeatedSpeedPoliciesKeepUnpublishedUltrafastOutOfStandardTotals() throws {
        let pricing = snapshot([
            "gpt-6-astra": rates(2), "gpt-6-astra-ultrafast": rates(9),
            "custom-fast": rates(7), "gpt-6-sol": rates(3)
        ])
        let events = [
            event(0, model: "gpt-6-astra"),
            event(1, model: "gpt-6-astra", isFast: true),
            event(2, model: "gpt-6-astra", isFast: true, isUltrafast: true),
            event(3, model: "gpt-6-astra-ultrafast", isFast: true),
            event(4, model: "custom-fast"),
            event(5, model: "custom-fast", isFast: true),
            event(6, model: "gpt-6-sol"),
            event(7, model: "gpt-6-sol", isUltrafast: true),
            event(8, model: "gpt-6-sol", input: 2_000, isUltrafast: true),
            event(9, model: "gpt-6-astra", input: 2_000, isUltrafast: true)
        ]

        for ordered in [events, Array(events.reversed())] {
            let scan = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)

            XCTAssertEqual(scan.series.daily.count, 1)
            try assertDay(scan, date: "2026-09-12", tokens: 9_000, cost: 0.059, models: [
                "gpt-6-astra": (5_000, 0.033),
                "gpt-6-astra-ultrafast": (1_000, 0.009),
                "custom-fast": (2_000, 0.014),
                "gpt-6-sol": (1_000, 0.003)
            ])
            XCTAssertEqual(scan.unknownModelsByDay, ["2026-09-12": ["gpt-6-sol (Ultrafast)"]])
        }
    }

    func testNewSnapshotRepricesSameEventsWithoutLeakingMissesOrFastMultipliers() throws {
        let original = snapshot(["gpt-6-sol": rates(2, fast: 2)])
        let refreshed = snapshot([
            "gpt-6-sol": rates(4, fast: 3), "newly-priced-model": rates(5)
        ])
        let events = [
            event(0, model: "gpt-6-sol", isFast: true),
            event(1, model: "gpt-6-sol", input: 2_000, isFast: true),
            event(2, model: "newly-priced-model")
        ]

        for ordered in [events, Array(events.reversed())] {
            for pricing in [original, refreshed, original] {
                let scan = CodexLogUsageScanner.aggregate(events: ordered, since: .distantPast, pricing: pricing)

                XCTAssertEqual(scan.series.daily.count, 1)
                if pricing === refreshed {
                    try assertDay(scan, date: "2026-09-12", tokens: 4_000, cost: 0.041, models: [
                        "gpt-6-sol": (3_000, 0.036), "newly-priced-model": (1_000, 0.005)
                    ])
                    XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
                } else {
                    try assertDay(scan, date: "2026-09-12", tokens: 3_000, cost: 0.012,
                                  models: ["gpt-6-sol": (3_000, 0.012)])
                    XCTAssertEqual(scan.unknownModelsByDay, ["2026-09-12": ["newly-priced-model"]])
                }
            }
        }
    }

    private func event(
        _ index: Int, model: String, day: Int = 0, input: Int = 1_000, cached: Int = 0,
        output: Int = 0, isFast: Bool = false, isUltrafast: Bool = false, pricingModel: String? = nil
    ) -> CodexLogUsageScanner.Event {
        let timestamp = Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 12 + day, hour: 12, second: index
        ))!
        return .init(timestamp: timestamp, model: model, input: input, cached: cached,
                     output: output, reasoning: 0, total: input + output,
                     isFast: isFast, isUltrafast: isUltrafast, pricingModel: pricingModel)
    }

    private func rates(_ input: Double, fast: Double = 1) -> ModelRates {
        .init(inputPerMillion: input, outputPerMillion: input * 2,
              cacheWritePerMillion: input, cacheReadPerMillion: input / 4, fastMultiplier: fast)
    }

    private func snapshot(_ rates: [String: ModelRates]) -> ModelPricing {
        .init(supplement: PricingSupplement(pricing: rates),
              primary: PricingCatalog(), secondary: PricingCatalog())
    }

    private func assertDay(
        _ scan: LogUsageScan, date: String, tokens: Int, cost: Double,
        models: [String: (tokens: Int, cost: Double)], file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let day = try XCTUnwrap(scan.series.daily.first { $0.date == date }, file: file, line: line)
        XCTAssertEqual(day.totalTokens, tokens, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(day.costUSD, file: file, line: line), cost,
                       accuracy: 1e-9, file: file, line: line)
        let breakdown = try XCTUnwrap(scan.modelUsage?.daily.first { $0.date == date }, file: file, line: line)
        XCTAssertEqual(breakdown.models.count, models.count, file: file, line: line)
        XCTAssertEqual(Set(breakdown.models.map(\.model)), Set(models.keys), file: file, line: line)
        for (name, expected) in models {
            let actual = try XCTUnwrap(breakdown.models.first { $0.model == name }, file: file, line: line)
            XCTAssertEqual(actual.totalTokens, expected.tokens, file: file, line: line)
            XCTAssertEqual(try XCTUnwrap(actual.costUSD, file: file, line: line), expected.cost,
                           accuracy: 1e-9, file: file, line: line)
        }
        XCTAssertEqual(scan.rejectedNumericRows, 0, file: file, line: line)
        XCTAssertEqual(scan.unsupportedPricingRows, 0, file: file, line: line)
    }
}
