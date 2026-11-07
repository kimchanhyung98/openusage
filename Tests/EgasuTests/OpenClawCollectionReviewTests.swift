import XCTest
@testable import Egasu

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
            XCTAssertEqual(roots, ["agents", "sessions"].map {
                home.appendingPathComponent(".openclaw-\(profile.trimmingCharacters(in: .whitespacesAndNewlines))/" + $0)
            })
        }
        let explicit = UsageSourceCollectors.openClawRoots(environment: FakeEnvironment([
            "OPENCLAW_PROFILE": " dev ", "OPENCLAW_STATE_DIR": "/chosen/state"
        ]), home: home)
        XCTAssertEqual(explicit, ["agents", "sessions"].map { URL(fileURLWithPath: "/chosen/state/" + $0) })
    }

    func testHomeSentinelsFallBackToHomeWhileStateOverrideAndOrdinaryPathsRemainValid() {
        let home = URL(fileURLWithPath: "/fixture")
        let defaults = UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(), home: home)
        for value in ["undefined", "null", " undefined ", " null\n", "", " "] {
            let environment = FakeEnvironment(["OPENCLAW_HOME": value])
            XCTAssertEqual(UsageSourceCollectors.openClawRoots(environment: environment, home: home), defaults, value)
        }
        for value in ["/chosen/null", "~/chosen", "UNDEFINED"] {
            let environment = FakeEnvironment(["OPENCLAW_HOME": value])
            let base = UsageSourceCollectors.configured("OPENCLAW_HOME", environment: environment, home: home)
            XCTAssertNotNil(base, value)
            XCTAssertEqual(UsageSourceCollectors.openClawRoots(environment: environment, home: home).first,
                           base?.appendingPathComponent(".openclaw/agents"), value)
        }
        let environment = FakeEnvironment(["OPENCLAW_HOME": "null", "OPENCLAW_STATE_DIR": "~/state"])
        XCTAssertEqual(UsageSourceCollectors.openClawRoots(environment: environment, home: home),
                       ["agents", "sessions"].map { home.appendingPathComponent("state/" + $0) })
    }

    func testLegacyTopLevelTranscriptsAreCollectedAndDeduplicatedWithPerAgentCopies() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let cases: [(environment: [String: String], state: String)] = [
            ([:], ".openclaw"), ([:], ".clawdbot"), ([:], ".moltbot"), ([:], ".moldbot"),
            (["OPENCLAW_PROFILE": "work"], ".openclaw-work"),
            (["OPENCLAW_STATE_DIR": home.appendingPathComponent("custom").path], "custom"),
            (["OPENCLAW_HOME": home.appendingPathComponent("relocated").path], "relocated/.openclaw")
        ]
        for entry in cases {
            let text = OpenClawTestStore.header + "\n" + (try OpenClawTestStore.message(id: "same", cost: 0.25))
            let state = home.appendingPathComponent(entry.state)
            try UsageRecordFixture.write(text, to: state.appendingPathComponent("sessions/s1.jsonl"))
            try UsageRecordFixture.write(text, to: state.appendingPathComponent("agents/main/sessions/s1.jsonl"))
            let configured = try XCTUnwrap(UsageSourceCollectors.make(environment: FakeEnvironment(entry.environment), home: home)
                .compactMap { $0 as? UsageFileCollector }.first { $0.sourceID == "openclaw" })
            let collector = UsageFileCollector(
                sourceID: "openclaw", roots: configured.roots, scanner: IncrementalJSONLScanner(),
                includeFile: configured.includeFile, parse: OpenClawSessionParser.parse
            )
            let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
            let result = try XCTUnwrap(collected)
            XCTAssertEqual(result.records.count, 1, entry.state)
            XCTAssertEqual(result.records.first?.totalTokens, 120, entry.state)
            XCTAssertEqual(result.readFailureCount, 0, entry.state)
            try FileManager.default.removeItem(at: state)
        }
    }

    func testSQLiteFixtureFailureIncludesTheSQLiteDiagnostic() throws {
        let store = try OpenClawTestStore()
        XCTAssertThrowsError(try store.execute("INSERT INTO missing_fixture_table VALUES(1)")) { error in
            XCTAssertEqual((error as NSError).domain, "OpenClawTestStore")
            XCTAssertTrue(error.localizedDescription.contains("missing_fixture_table"))
        }
    }

    func testIncompleteTailPreservesCompleteUsageAndRecoversOnTheNextScan() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("s1.jsonl")
        let first = try OpenClawTestStore.message(id: "first", cost: 0.25)
        let prefix = OpenClawTestStore.header + "\n" + first + "\n"
        try UsageRecordFixture.write(prefix + #"{"type":"message","message":"#, to: file)
        let collector = UsageFileCollector(
            sourceID: "openclaw", roots: [file], scanner: IncrementalJSONLScanner(),
            includeFile: { _ in true }, parse: OpenClawSessionParser.parse
        )

        let firstCollection = await collector.collect(since: .distantPast)
        let partial = try XCTUnwrap(firstCollection)
        let expected = try OpenClawSessionParser.parse(Data(prefix.utf8), path: file.path)
        XCTAssertEqual(partial.records.first, expected.first)
        XCTAssertEqual(partial.readFailureCount, 0)
        let diagnostic = try XCTUnwrap(partial.records.last)
        XCTAssertEqual(diagnostic.kind, "incomplete-tail")
        XCTAssertEqual(diagnostic.sessionID, "s1")
        XCTAssertNil(diagnostic.providerID)
        XCTAssertNil(diagnostic.model)
        XCTAssertEqual(diagnostic.issues, [.invalidMetadata])
        XCTAssertEqual(diagnostic.totalTokens, 0)
        XCTAssertNil(diagnostic.recordedCostUSD)
        let partialScan = try XCTUnwrap(UsageHistoryBuilder.scan(
            partial, providerID: "claude", since: .distantPast, pricing: .empty, allowEstimates: false
        ))
        XCTAssertEqual(partialScan.series.daily.first?.totalTokens, 120)
        XCTAssertEqual(partialScan.series.daily.first?.costUSD, 0.25)
        XCTAssertNotNil(partialScan.usageHistory)

        let second = try OpenClawTestStore.message(id: "second", cost: 0.5)
        try UsageRecordFixture.write(prefix + second, to: file)
        let secondCollection = await collector.collect(since: .distantPast)
        let complete = try XCTUnwrap(secondCollection)
        XCTAssertEqual(complete.records.count, 2)
        XCTAssertTrue(complete.records.allSatisfy { $0.issues.isEmpty })
        XCTAssertEqual(complete.records.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertEqual(complete.readFailureCount, 0)
    }

    func testCompleteFinalRowDoesNotRequireANewline() throws {
        let message = try OpenClawTestStore.message(id: "complete", cost: 0.25)
        let text = OpenClawTestStore.header + "\n" + message

        let records = try OpenClawSessionParser.parse(Data(text.utf8), path: "/fixture/s1.jsonl")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, "complete")
        XCTAssertEqual(records.first?.totalTokens, 120)
        XCTAssertTrue(records.first?.issues.isEmpty == true)
    }

    func testNewlineTerminatedCorruptionStillFailsTheTranscript() throws {
        let message = try OpenClawTestStore.message(id: "complete", cost: 0.25)
        let prefix = OpenClawTestStore.header + "\n" + message + "\n"
        let broken = #"{"type":"message","message":"# + "\n"
        for text in [prefix + broken, prefix + broken + message] {
            XCTAssertThrowsError(try OpenClawSessionParser.parse(Data(text.utf8), path: "/fixture/s1.jsonl"))
        }
    }

    func testIncompleteOnlyTranscriptRetainsAnUnattributedDiagnostic() throws {
        let records = try OpenClawSessionParser.parse(Data(#"{"type":"message"#.utf8), path: "/fixture/s1.jsonl")

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.kind, "incomplete-tail")
        XCTAssertEqual(records.first?.issues, [.invalidMetadata])
        XCTAssertNil(records.first?.providerID)
        XCTAssertNil(records.first?.model)
        XCTAssertEqual(records.first?.totalTokens, 0)
        XCTAssertNil(records.first?.recordedCostUSD)
    }

    func testCompleteCompressedFrameCanContainAnIncompleteJSONLTailButTornFrameFails() throws {
        let prefix = OpenClawTestStore.header + "\n" + (try OpenClawTestStore.message(id: "complete", cost: 0.25)) + "\n"
        let bytes = try OpenClawTestStore.compress(Data((prefix + #"{"type":"message"#).utf8))

        let records = try OpenClawSessionParser.parse(bytes, path: "/fixture/s1.jsonl.zst")

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.totalTokens, 120)
        XCTAssertEqual(records.last?.kind, "incomplete-tail")
        XCTAssertThrowsError(try OpenClawSessionParser.parse(Data(bytes.dropLast()), path: "/fixture/s1.jsonl.zst"))
    }

    func testRelocatedTopLevelSessionsCollectsSupportedFormatsAndFileAliases() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".openclaw/sessions")
        let external = home.appendingPathComponent("foreign-history")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: external)
        let names = ["plain.jsonl", "compressed.jsonl.zst", "deleted.jsonl.deleted.now.zst", "reset.jsonl.reset.now.zst"]
        for name in names {
            let text = OpenClawTestStore.header + "\n" + (try OpenClawTestStore.message(id: name, cost: 0.25))
            let bytes = Data(text.utf8)
            try UsageRecordFixture.write(name.hasSuffix(".zst") ? OpenClawTestStore.compress(bytes) : bytes,
                                         to: external.appendingPathComponent(name))
        }
        let aliasPayload = home.appendingPathComponent("payload.checkpoint.data")
        try UsageRecordFixture.write(OpenClawTestStore.message(id: "alias", cost: 0.25), to: aliasPayload)
        try FileManager.default.createSymbolicLink(at: external.appendingPathComponent("alias.jsonl"), withDestinationURL: aliasPayload)
        for name in ["cold/blob.jsonl.zst", "snapshot.checkpoint.1.jsonl.zst", "notes.txt"] {
            try UsageRecordFixture.write(OpenClawTestStore.message(id: "excluded", cost: 9), to: external.appendingPathComponent(name))
        }
        let collector = UsageSourceCollectors.openClawCollector(
            roots: UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(), home: home),
            scanner: IncrementalJSONLScanner()
        )

        let collected = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)

        XCTAssertEqual(Set(result.records.compactMap(\.id)), Set(names + ["alias"]))
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 600)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertTrue(result.records.allSatisfy { $0.issues.isEmpty })
    }

    func testAgentTranscriptAndImportArchiveScopeStillExcludesColdAndCheckpoints() async throws {
        for linked in [false, true] {
            let home = try UsageRecordFixture.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: home) }
            let agents = home.appendingPathComponent(".openclaw/agents")
            if linked {
                let external = home.appendingPathComponent("foreign-agent-store")
                try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: agents.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: agents, withDestinationURL: external)
            }
            try UsageRecordFixture.write(OpenClawTestStore.message(id: "active", cost: 0.25),
                                         to: agents.appendingPathComponent("main/sessions/active.jsonl"))
            let archived = try OpenClawTestStore.message(id: "imported", cost: 0.5, input: 200, output: 40)
            try UsageRecordFixture.write(OpenClawTestStore.compress(Data(archived.utf8)),
                                         to: agents.appendingPathComponent("main/session-sqlite-import-archive/run/imported.jsonl.zst"))
            for name in ["main/sessions/cold/blob.jsonl.zst", "main/sessions/active.checkpoint.1.jsonl",
                         "main/session-sqlite-import-archive/run/old.checkpoint.1.jsonl", "main/other.jsonl"] {
                try UsageRecordFixture.write(OpenClawTestStore.message(id: "excluded", cost: 9), to: agents.appendingPathComponent(name))
            }
            let collector = UsageSourceCollectors.openClawCollector(
                roots: UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(), home: home),
                scanner: IncrementalJSONLScanner()
            )

            let collected = await collector.collect(since: .distantPast)
            let result = try XCTUnwrap(collected)

            XCTAssertEqual(Set(result.records.compactMap(\.id)), ["active", "imported"])
            XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 360)
            XCTAssertEqual(result.readFailureCount, 0)
        }
    }

    func testWarmCollectorFollowsReplacedTopLevelSessionsLink() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".openclaw/sessions")
        let first = home.appendingPathComponent("foreign-first")
        let second = home.appendingPathComponent("foreign-second")
        try UsageRecordFixture.write(OpenClawTestStore.message(id: "first", cost: 0.25), to: first.appendingPathComponent("same.jsonl"))
        try UsageRecordFixture.write(OpenClawTestStore.message(id: "second", cost: 0.75, input: 300, output: 60),
                                     to: second.appendingPathComponent("same.jsonl"))
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: first)
        let collector = UsageSourceCollectors.openClawCollector(
            roots: UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(), home: home),
            scanner: IncrementalJSONLScanner()
        )
        let initial = await collector.collect(since: .distantPast)
        XCTAssertEqual(initial?.records.map(\.id), ["first"])
        XCTAssertEqual(initial?.records.first?.totalTokens, 120)
        XCTAssertEqual(initial?.readFailureCount, 0)

        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: second)
        let replaced = await collector.collect(since: .distantPast)

        XCTAssertEqual(replaced?.records.map(\.id), ["second"])
        XCTAssertEqual(replaced?.records.first?.totalTokens, 360)
        XCTAssertEqual(replaced?.readFailureCount, 0)
    }


    func testTemporarySidecarsAreExcludedWhileOfficialPlainAndCompressedArchivesRemainReadable() async throws {
        let home = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".openclaw/sessions")
        let generation = "0123456789abcdef0123456789abcdef"
        let stamps = ["2026-11-01T09-00-00Z", "2026-11-01T09-00-00.123Z", "2026-11-01T09-00-00.123Z." + generation]
        var names = ["active.jsonl", "compressed.jsonl.zst"]
        for reason in ["deleted", "reset"] {
            for stamp in stamps {
                names += ["s1.jsonl.\(reason).\(stamp)", "s1.jsonl.\(reason).\(stamp).zst"]
            }
        }
        for name in names {
            let data = Data(try OpenClawTestStore.message(id: name, cost: 0.25).utf8)
            try UsageRecordFixture.write(name.hasSuffix(".zst") ? OpenClawTestStore.compress(data) : data,
                                         to: sessions.appendingPathComponent(name))
            for suffix in [".tmp", ".01234567-89ab-4cde-8123-456789abcdef.tmp"] {
                try UsageRecordFixture.write("{unfinished\n", to: sessions.appendingPathComponent(name + suffix))
            }
        }
        try UsageRecordFixture.write("{unfinished\n", to: sessions.appendingPathComponent("s1.jsonl.deleted.2026-11-01.tmp"))
        let collector = UsageSourceCollectors.openClawCollector(
            roots: UsageSourceCollectors.openClawRoots(environment: FakeEnvironment(), home: home),
            scanner: IncrementalJSONLScanner()
        )

        let collected = await collector.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)

        XCTAssertEqual(result.records.count, 14)
        XCTAssertEqual(Set(result.records.compactMap(\.id)), Set(names))
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 1680)
        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertTrue(result.records.allSatisfy { $0.issues.isEmpty })
    }

}
