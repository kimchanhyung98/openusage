import XCTest
@testable import OpenUsage

@MainActor
final class OpenClawCollectionReviewTests: XCTestCase {
    func testProviderBilledZeroAndPositiveCostsSurviveWhenEstimatesAreDisabled() throws {
        for cost in [0.0, 0.25] {
            let row = try OpenClawTestStore.message(id: "reported", provider: "opencode", cost: cost)
            let records = try OpenClawSessionParser.parse(Data(row.utf8), path: "/fixture/session.jsonl")
            let record = try XCTUnwrap(records.first)
            XCTAssertEqual(record.costOrigin, .reported)
            XCTAssertFalse(record.zeroCostIsUnknown)
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                UsageCollection(records: records), providerID: "opencode", since: .distantPast, pricing: .empty,
                costEstimator: { _, _ in .priced(99) }, allowEstimates: false
            ))
            XCTAssertEqual(scan.series.daily.first?.costUSD, cost)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 120)
        }
    }

    func testUnmarkedOpenClawCostDoesNotUsePiProviderFlag() throws {
        var object = try UsageJSON.object(Data(OpenClawTestStore.message(id: "estimated", provider: "opencode", cost: 0).utf8))
        var message = try XCTUnwrap(object["message"] as? [String: Any])
        var usage = try XCTUnwrap(message["usage"] as? [String: Any])
        usage["cost"] = ["total": 0.25, "totalFromProvider": true]
        message["usage"] = usage
        object["message"] = message
        let records = try OpenClawSessionParser.parse(JSONSerialization.data(withJSONObject: object), path: "/fixture/session.jsonl")
        XCTAssertEqual(records.first?.costOrigin, .estimated)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
            UsageCollection(records: records), providerID: "opencode", since: .distantPast, pricing: .empty, allowEstimates: false
        ))
        XCTAssertNil(scan.series.daily.first?.costUSD)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 120)
    }

    func testUnavailableUsageIsRetainedButExcludedWithWarningWhileReportedZeroRemainsValid() throws {
        let unavailable = try OpenClawTestStore.message(id: "partial", cost: 5, report: "unavailable")
        let zero = try OpenClawTestStore.message(id: "zero", cost: 0, input: 0, output: 0, report: "available")
        let records = try OpenClawSessionParser.parse(Data((unavailable + "\n" + zero).utf8), path: "/fixture/session.jsonl")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.totalTokens, 120)
        XCTAssertTrue(records.first?.issues.contains(.invalidMetadata) == true)
        XCTAssertTrue(records.last?.issues.isEmpty == true)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
            UsageCollection(records: records), providerID: "claude", since: .distantPast, pricing: .empty
        ))
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
        XCTAssertNotNil(scan.metadataWarning)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 0)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0)
    }

    func testCompressedDeletedResetAndPlainTranscriptsCountOneRequest() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let text = OpenClawTestStore.header + "\n" + (try OpenClawTestStore.message(id: "e1", cost: 0.25))
        let data = Data(text.utf8)
        let compressed = try OpenClawTestStore.compress(data)
        for name in ["s1.jsonl", "s1.jsonl.deleted.2026-11-01.zst", "s1.jsonl.reset.2026-11-01.zst", "s1.jsonl.zst"] {
            try UsageRecordFixture.write(name == "s1.jsonl" ? data : compressed, to: directory.appendingPathComponent(name))
        }
        let collector = UsageFileCollector(
            sourceID: "openclaw", roots: [directory], scanner: IncrementalJSONLScanner(),
            includeFile: { _ in true }, parse: OpenClawSessionParser.parse
        )
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.totalTokens, 120)
        XCTAssertEqual(result.records.first?.recordedCostUSD, 0.25)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertThrowsError(try OpenClawSessionParser.parse(compressed.dropLast(), path: "/fixture/s1.jsonl.deleted.now.zst"))
    }

    func testRegistrySelectsCompressedTranscriptsButLeavesColdEnvelopesToDatabase() throws {
        let home = URL(fileURLWithPath: "/fixture")
        let collector = try XCTUnwrap(UsageSourceCollectors.make(environment: FakeEnvironment(), home: home)
            .compactMap { $0 as? UsageFileCollector }.first { $0.sourceID == "openclaw" })
        let root = home.appendingPathComponent(".openclaw/agents/main/sessions")
        XCTAssertTrue(collector.includeFile(root.appendingPathComponent("s1.jsonl.zst")))
        XCTAssertTrue(collector.includeFile(root.appendingPathComponent("s1.jsonl.deleted.now.zst")))
        XCTAssertFalse(collector.includeFile(root.appendingPathComponent("s1.checkpoint.1.jsonl.zst")))
        XCTAssertFalse(collector.includeFile(root.appendingPathComponent("cold/" + String(repeating: "a", count: 64) + ".jsonl.zst")))
    }

    func testProfileNormalizationMatchesOfficialRulesAndStateOverrideWins() {
        let home = URL(fileURLWithPath: "/fixture")
        for profile in ["DEFAULT", " default \n", "-bad", "_bad", String(repeating: "a", count: 65)] {
            let roots = UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(["OPENCLAW_PROFILE": profile]), home: home)
            XCTAssertEqual(roots.first, home.appendingPathComponent(".openclaw/agents"), profile)
        }
        for profile in [" dev ", "Work_1", String(repeating: "a", count: 64)] {
            let roots = UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(["OPENCLAW_PROFILE": profile]), home: home)
            XCTAssertEqual(roots, [home.appendingPathComponent(".openclaw-\(profile.trimmingCharacters(in: .whitespacesAndNewlines))/agents")])
        }
        let explicit = UsageSourceCollectors.openClawRoots(environment: FakeEnvironment([
            "OPENCLAW_PROFILE": " dev ", "OPENCLAW_STATE_DIR": "/chosen/state"
        ]), home: home)
        XCTAssertEqual(explicit, [URL(fileURLWithPath: "/chosen/state/agents")])
    }
}
