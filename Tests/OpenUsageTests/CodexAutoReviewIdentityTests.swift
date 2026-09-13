import Foundation
import XCTest
@testable import OpenUsage

final class CodexAutoReviewIdentityTests: XCTestCase {
    private let timestamp = "2026-05-12T08:00:00Z"

    func testExplicitAndInheritedAutoReviewKeepTheirIdentity() {
        let lines = [
            line(model: "codex-auto-review"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-05-12T08:01:00Z",
                last: CodexLogFixture.usage(input: 20, output: 10)
            ),
        ].joined(separator: "\n")

        let events = CodexLogUsageScanner.parseFile(Data(lines.utf8))

        XCTAssertEqual(events.map(\.model), ["codex-auto-review", "codex-auto-review"])
        XCTAssertEqual(events.map(\.pricingModel), ["gpt-5.5", "gpt-5.5"])
    }

    func testDistinctModelsWithIdenticalCountsSurviveDeduplication() throws {
        let data = Data([line(model: "codex-auto-review"), line(model: "gpt-5.5")].joined(separator: "\n").utf8)
        let events = CodexLogUsageScanner.parseFile(data)
        let scan = CodexLogUsageScanner.aggregate(
            events: events + events, since: .distantPast, pricing: pricing()
        )

        let daily = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(daily.totalTokens, 300)
        XCTAssertEqual(try XCTUnwrap(daily.costUSD), 0.5, accuracy: 0.000001)
        let models = try XCTUnwrap(scan.modelUsage?.daily.first?.models)
        XCTAssertEqual(Set(models.map(\.model)), ["codex-auto-review", "gpt-5.5"])
        for model in models {
            XCTAssertEqual(model.totalTokens, 150)
            XCTAssertEqual(try XCTUnwrap(model.costUSD), 0.25, accuracy: 0.000001)
        }
    }

    func testReferencePricingPreservesCostAndUnknownWarningUsesDisplayName() throws {
        let events = CodexLogUsageScanner.parseFile(Data(line(model: "codex-auto-review").utf8))
        var previouslyRewritten = try XCTUnwrap(events.first)
        previouslyRewritten.model = "gpt-5.5"
        previouslyRewritten.pricingModel = nil
        let current = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing())
        let previous = CodexLogUsageScanner.aggregate(
            events: [previouslyRewritten], since: .distantPast, pricing: pricing()
        )
        XCTAssertEqual(current.series.daily, previous.series.daily)

        let unknown = CodexLogUsageScanner.aggregate(
            events: events, since: .distantPast, pricing: pricing(entries: [:])
        )
        XCTAssertTrue(unknown.series.daily.isEmpty)
        XCTAssertEqual(Set(unknown.unknownModelsByDay.values.flatMap { $0 }), ["codex-auto-review"])
    }

    func testReferenceDateBoundariesAndLegacyLogs() {
        let cases = [
            ("2026-04-22T23:59:59Z", "gpt-5.4"),
            ("2026-04-23T00:00:00Z", "gpt-5.5"),
            ("2026-09-13T00:00:00Z", "gpt-5.5"),
            ("2025-08-06T23:59:59Z", "gpt-5"),
        ]
        for (date, expected) in cases {
            let data = Data(CodexLogFixture.tokenCount(
                timestamp: date, last: CodexLogFixture.usage(input: 10, output: 5),
                model: "codex-auto-review"
            ).utf8)
            let event = CodexLogUsageScanner.parseFile(data).first
            XCTAssertEqual(event?.model, "codex-auto-review")
            XCTAssertEqual(event?.pricingModel, expected)
        }
        let legacy = CodexLogUsageScanner.parseFile(Data(line(model: nil).utf8)).first
        XCTAssertEqual(legacy?.model, "gpt-5")
        XCTAssertNil(legacy?.pricingModel)
        let invalid = CodexLogFixture.tokenCount(
            timestamp: "invalid", last: CodexLogFixture.usage(input: 10, output: 5),
            model: "codex-auto-review"
        )
        XCTAssertTrue(CodexLogUsageScanner.parseFile(Data(invalid.utf8)).isEmpty)
    }

    func testReferenceModelStillUsesFastTierForPricing() throws {
        let data = Data([
            CodexLogFixture.threadSettingsApplied(timestamp: timestamp, serviceTier: "fast"),
            line(model: "codex-auto-review"),
        ].joined(separator: "\n").utf8)
        let events = CodexLogUsageScanner.parseFile(data)
        let scan = CodexLogUsageScanner.aggregate(events: events, since: .distantPast, pricing: pricing())
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.625, accuracy: 0.000001)
        XCTAssertEqual(scan.modelUsage?.daily.first?.models.first?.model, "codex-auto-review")
    }

    func testCachesWithoutReviewIdentityReparseOriginalLogsForScopedScanner() async throws {
        for version in [1, 4] {
            try await assertCacheRebuild(version: version)
        }
    }

    private func assertCacheRebuild(version: Int) async throws {
        let home = try CodexLogFixture.makeHome(files: ["sessions/review.jsonl": line(model: "codex-auto-review")])
        defer { try? FileManager.default.removeItem(at: home) }
        let files = JSONLScanning.jsonlFiles(under: home.appendingPathComponent("sessions"))
        let cache = home.appendingPathComponent("cache")
        let old = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence: JSONLScanCachePersistence(
                namespace: "codex", schemaVersion: version, directory: cache, writeDebounce: .milliseconds(1)
            )
        )
        let seeded = await old.items(from: files, since: .distantPast, cacheIdentity: "account-a") { data in
            CodexLogUsageScanner.parseFile(data).map { event in
                var oldEvent = event
                oldEvent.model = event.pricingModel ?? event.model
                oldEvent.pricingModel = nil
                return oldEvent
            }
        }
        XCTAssertEqual(seeded?.first?.model, "gpt-5.5")
        await old.waitForPendingWritesForTesting()

        let rebuilt = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence: JSONLScanCachePersistence(
                namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion,
                directory: cache, writeDebounce: .milliseconds(1)
            )
        )
        let scanner = CodexLogUsageScanner(
            incrementalScanner: rebuilt, cacheIdentityOverride: "account-a", rootsOverride: [home]
        )
        let scan = await scanner.scan(
            now: OpenUsageISO8601.date(from: "2026-05-13T08:00:00Z")!, pricing: pricing()
        )
        XCTAssertEqual(scan?.modelUsage?.daily.first?.models.first?.model, "codex-auto-review")
        await rebuilt.waitForPendingWritesForTesting()

        let relaunched = IncrementalJSONLScanner<CodexLogUsageScanner.Event>(
            persistence: JSONLScanCachePersistence(
                namespace: "codex", schemaVersion: CodexLogUsageScanner.cacheSchemaVersion,
                directory: cache, writeDebounce: .milliseconds(1)
            )
        )
        let cached = await relaunched.items(from: files, since: .distantPast, cacheIdentity: "account-a") { _ in [] }
        XCTAssertEqual(cached?.first?.model, "codex-auto-review")
        XCTAssertEqual(cached?.first?.pricingModel, "gpt-5.5")
        await relaunched.waitForPendingWritesForTesting()
    }

    private func line(model: String?) -> String {
        CodexLogFixture.tokenCount(
            timestamp: timestamp, last: CodexLogFixture.usage(input: 100, output: 50), model: model
        )
    }

    private func pricing(entries: [String: ModelRates]? = nil) -> ModelPricing {
        ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: entries ?? [
                "gpt-5.5": ModelRates(
                    inputPerMillion: 1_000, outputPerMillion: 3_000,
                    cacheWritePerMillion: 1_000, cacheReadPerMillion: 100
                ),
            ]),
            secondary: PricingCatalog(entries: [:])
        )
    }
}
