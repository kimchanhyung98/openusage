import SQLite3
import XCTest
@testable import OpenUsage

@MainActor
final class HermesUsageReviewTests: XCTestCase {
    func testAuxiliaryOnlyLedgerKeepsEntireMainSession() async throws {
        let database = try HermesReviewDatabase()
        try database.model(input: 100, output: 10, task: "compression")

        let collection = try await database.collect()
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

        XCTAssertEqual(collection.records.count, 2)
        XCTAssertEqual(collection.records.first { $0.kind == "session-total" }?.totalTokens, 1100)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1210)
        XCTAssertNil(scan.metadataWarning)
    }

    func testPartialMainCoverageKeepsResidualAndSeparateAuxiliaryCost() async throws {
        let database = try HermesReviewDatabase()
        try database.execute("UPDATE sessions SET estimated_cost_usd=0.5,cost_status='estimated'")
        try database.model(input: 400, output: 40, cost: 0.2)
        try database.model(input: 100, output: 10, task: "compression", cost: 0.05)

        let collection = try await database.collect()
        let residual = try XCTUnwrap(collection.records.first { $0.kind == "session-residual" })
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

        XCTAssertEqual(residual.totalTokens, 660)
        XCTAssertEqual(try XCTUnwrap(residual.recordedCostUSD), 0.3, accuracy: 1e-9)
        XCTAssertTrue(residual.issues.isEmpty)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1210)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.55, accuracy: 1e-9)
        XCTAssertNil(scan.metadataWarning)
    }

    func testCompleteMainCoverageAndVoiceRouteDoNotAddSessionAgain() async throws {
        let database = try HermesReviewDatabase()
        try database.model(input: 400, output: 40)
        try database.model(input: 600, output: 60, task: "voice_chat")
        try database.model(input: 100, output: 10, task: "compression")

        let collection = try await database.collect()
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

        XCTAssertEqual(collection.records.count, 3)
        XCTAssertTrue(collection.records.allSatisfy { $0.kind == "model-total" })
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1210)
        XCTAssertNil(scan.metadataWarning)
    }

    func testResidualSubtractsCacheBucketsWithoutAddingReasoningAgain() async throws {
        let database = try HermesReviewDatabase()
        try database.execute("UPDATE sessions SET cache_read_tokens=300,cache_write_tokens=50,reasoning_tokens=40")
        try database.model(input: 400, output: 40)
        try database.execute("UPDATE session_model_usage SET cache_read_tokens=100,cache_write_tokens=20,reasoning_tokens=10")

        let collection = try await database.collect()
        let residual = try XCTUnwrap(collection.records.first { $0.kind == "session-residual" })
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

        XCTAssertEqual(residual.totalTokens, 890)
        XCTAssertEqual(residual.tokens?.cacheRead, 200)
        XCTAssertEqual(residual.tokens?.cacheWrite5m, 30)
        XCTAssertEqual(residual.reasoningTokens, 30)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1450)
    }

    func testExcessModelReasoningKeepsUnresolvedSessionInsteadOfResidual() async throws {
        let database = try HermesReviewDatabase()
        try database.execute("UPDATE sessions SET reasoning_tokens=10")
        try database.model(input: 400, output: 40)
        try database.execute("UPDATE session_model_usage SET reasoning_tokens=15")
        let collection = try await database.collect()
        let original = try XCTUnwrap(collection.records.first { $0.kind == "session-total" })
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(original.reasoningTokens, 10)
        XCTAssertTrue(original.issues.contains(.unresolvedMirror))
        XCTAssertNil(collection.records.first { $0.kind == "session-residual" })
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 440)
        XCTAssertNotNil(scan.metadataWarning)
    }

    func testDifferentRouteResidualStaysRawWithMetadataWarning() async throws {
        let database = try HermesReviewDatabase()
        try database.model(input: 400, output: 40)
        try database.execute("UPDATE session_model_usage SET model='claude-haiku-4-5'")

        let collection = try await database.collect()
        let residual = try XCTUnwrap(collection.records.first { $0.kind == "session-residual" })
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

        XCTAssertEqual(residual.totalTokens, 660)
        XCTAssertTrue(residual.issues.contains(.invalidMetadata))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 440)
        XCTAssertNotNil(scan.metadataWarning)
    }

    func testCompleteModelCostDoesNotRequireAnUnknownSessionCost() async throws {
        let database = try HermesReviewDatabase()
        try database.model(input: 1000, output: 100, cost: 0.2)

        let collection = try await database.collect()
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

        XCTAssertEqual(collection.records.count, 1)
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 1100)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.2)
        XCTAssertNil(scan.metadataWarning)
    }

    func testInvalidOrExcessMainCoverageKeepsOriginalWithoutDoubleCounting() async throws {
        for output in ["150", "-1", "'bad'"] {
            let database = try HermesReviewDatabase()
            try database.model(input: 400, output: 40)
            try database.execute("UPDATE session_model_usage SET output_tokens=\(output)")

            let collection = try await database.collect()
            let original = try XCTUnwrap(collection.records.first { $0.kind == "session-total" })
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: .distantPast, pricing: .empty))

            XCTAssertEqual(original.totalTokens, 1100)
            XCTAssertTrue(original.issues.contains(.unresolvedMirror))
            XCTAssertEqual(scan.series.daily.first?.totalTokens ?? 0, output == "150" ? 550 : 0)
            XCTAssertNotNil(scan.metadataWarning)
        }
    }

    func testCoverageSumOverflowKeepsUnresolvedSession() async throws {
        let database = try HermesReviewDatabase()
        try database.model(input: Int.max, output: 0)
        try database.model(input: 1, output: 0, task: "voice_chat")

        let collection = try await database.collect()

        XCTAssertTrue(collection.records.first { $0.kind == "session-total" }?.issues.contains(.unresolvedMirror) == true)
    }

    func testCodexBoundMainIsNotAddedToNativeRolloutButDirectAndAuxiliaryRemain() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HermesReviewDatabase(file: directory.appendingPathComponent(".hermes/state.db"))
        try database.execute("""
        UPDATE sessions SET model='gpt-5.2',billing_provider='openai-codex',input_tokens=100,output_tokens=10,
            cost_status='included',billing_mode='subscription_included',model_config='{"codex_thread_id":"native-thread"}';
        INSERT INTO sessions SELECT 'direct',model,billing_provider,started_at,ended_at,20,2,0,0,0,
            estimated_cost_usd,actual_cost_usd,cost_status,billing_base_url,billing_mode,NULL FROM sessions WHERE id='s';
        """)
        try database.model(input: 100, output: 10)
        try database.model(input: 10, output: 1, task: "compression")
        try database.execute("UPDATE session_model_usage SET model='gpt-5.2',billing_provider='openai-codex',cost_status='included',billing_mode='subscription_included'")
        let nativeLog = CodexLogFixture.tokenCount(
            timestamp: "2026-11-01T01:00:00Z", last: CodexLogFixture.usage(input: 100, output: 10), model: "gpt-5.2"
        )
        try UsageRecordFixture.write(nativeLog, to: directory.appendingPathComponent(".codex/sessions/rollout.jsonl"))
        let nativeScanner = CodexLogUsageScanner(environment: FakeEnvironment([:]), homeDirectory: { directory },
                                                 incrementalScanner: IncrementalJSONLScanner())
        let native = await nativeScanner.scan(now: Date(timeIntervalSince1970: 1793502000), pricing: TestPricing.bundled)
        let collection = try await database.collect()
        let shared = UsageHistoryBuilder.scan(collection, providerID: "codex", since: .distantPast, pricing: .empty)
        let merged = try XCTUnwrap(DailyUsageAccumulator.merged([native, shared]))

        let mirror = try XCTUnwrap(collection.records.first { $0.issues.contains(.unresolvedMirror) })
        XCTAssertEqual(mirror.mirroredSessionID, "native-thread")
        XCTAssertEqual(mirror.totalTokens, 110)
        XCTAssertEqual(collection.records.filter { !$0.issues.contains(.unresolvedMirror) }.reduce(0) { $0 + $1.totalTokens }, 33)
        XCTAssertEqual(merged.series.daily.reduce(0) { $0 + $1.totalTokens }, 143)
        XCTAssertNotNil(merged.metadataWarning)
    }

    func testMalformedCodexBindingCannotMasqueradeAsUnboundDirectUsage() async throws {
        for config in ["'broken'", "'{\"codex_thread_id\":false}'"] {
            let database = try HermesReviewDatabase()
            try database.execute("UPDATE sessions SET billing_provider='openai-codex',model_config=\(config)")

            let collection = try await database.collect()

            XCTAssertTrue(collection.records.first?.issues.contains(.invalidMetadata) == true)
            XCTAssertNil(collection.records.first?.mirroredSessionID)
        }
    }

    func testIncludedAndActualZeroRemainReportedWhileUnknownZeroIsPriced() async throws {
        for (status, mode, expected) in [("included", "subscription_included", 0.0), ("actual", "", 0), ("unknown", "", 0.7)] {
            let database = try HermesReviewDatabase()
            try database.execute("UPDATE sessions SET cost_status='\(status)',billing_mode='\(mode)'")

            let collection = try await database.collect()
            let record = try XCTUnwrap(collection.records.first)
            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
                collection, providerID: "claude", since: .distantPast, pricing: .empty, costEstimator: { _, _ in .priced(0.7) }
            ))

            XCTAssertEqual(record.costOrigin, status == "unknown" ? .estimated : .reported)
            XCTAssertEqual(record.zeroCostIsUnknown, status == "unknown")
            XCTAssertEqual(scan.series.daily.first?.costUSD, expected)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, 1100)
        }
    }

    func testSubscriptionBillingModePreservesIncludedZeroWhenStatusIsAbsent() async throws {
        let database = try HermesReviewDatabase()
        try database.execute("UPDATE sessions SET cost_status=NULL,billing_mode='subscription_included'")

        let collection = try await database.collect()

        XCTAssertEqual(collection.records.first?.recordedCostUSD, 0)
        XCTAssertEqual(collection.records.first?.costOrigin, .reported)
        XCTAssertEqual(collection.records.first?.zeroCostIsUnknown, false)
    }

    func testActualStatusInEstimatedColumnSurvivesReportedOnlyConsumer() async throws {
        let database = try HermesReviewDatabase()
        try database.execute("UPDATE sessions SET estimated_cost_usd=0.12,actual_cost_usd=0,cost_status='actual'")

        let collection = try await database.collect()
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(
            collection, providerID: "claude", since: .distantPast, pricing: .empty, allowEstimates: false
        ))

        XCTAssertEqual(collection.records.first?.recordedCostUSD, 0.12)
        XCTAssertEqual(collection.records.first?.costOrigin, .reported)
        XCTAssertEqual(scan.series.daily.first?.costUSD, 0.12)
    }

    func testMixedCostColumnsAndUnknownTotalsAreNotTreatedAsCompleteReportedCost() async throws {
        for (estimated, actual, status) in [(0.2, 0.1, "actual"), (0.2, 0.1, "estimated"), (0.2, 0, "unknown"), (0.2, 0, "included")] {
            let database = try HermesReviewDatabase()
            try database.execute("UPDATE sessions SET estimated_cost_usd=\(estimated),actual_cost_usd=\(actual),cost_status='\(status)'")

            let collection = try await database.collect()
            let reported = try XCTUnwrap(UsageHistoryBuilder.scan(
                collection, providerID: "claude", since: .distantPast, pricing: .empty, allowEstimates: false
            ))
            let estimatedScan = try XCTUnwrap(UsageHistoryBuilder.scan(
                collection, providerID: "claude", since: .distantPast, pricing: .empty, costEstimator: { _, _ in .priced(0.7) }
            ))

            XCTAssertNil(collection.records.first?.recordedCostUSD)
            XCTAssertEqual(collection.records.first?.costOrigin, .estimated)
            XCTAssertNil(reported.series.daily.first?.costUSD)
            XCTAssertEqual(estimatedScan.series.daily.first?.costUSD, 0.7)
            XCTAssertEqual(estimatedScan.series.daily.first?.totalTokens, 1100)
        }
    }

    func testInvalidCostDoesNotBecomeFreeUsage() async throws {
        for value in ["'bad'", "-1", "1e999"] {
            let database = try HermesReviewDatabase()
            try database.execute("UPDATE sessions SET actual_cost_usd=\(value),cost_status='actual'")

            let collection = try await database.collect()

            XCTAssertTrue(collection.records.first?.issues.contains(.invalidNumbers) == true)
            XCTAssertNil(collection.records.first?.recordedCostUSD)
        }
    }

    func testOverlappingResidualRemainsIncompleteAfterCollectionWindowStart() async throws {
        let database = try HermesReviewDatabase()
        try database.execute("UPDATE sessions SET ended_at=1793667600")
        try database.model(input: 400, output: 40)
        let since = Date(timeIntervalSince1970: 1793581200)

        let collection = try await database.collect(since: since)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(collection, providerID: "claude", since: since, pricing: .empty))

        XCTAssertEqual(collection.records.count, 1)
        XCTAssertEqual(collection.records.first?.kind, "session-residual")
        XCTAssertEqual(collection.records.first?.totalTokens, 660)
        XCTAssertTrue(collection.records.first?.issues.contains(.invalidMetadata) == true)
        XCTAssertNil(scan.usageHistory)
        XCTAssertNotNil(scan.metadataWarning)
    }

    func testDefaultProfileAndConfiguredHomeReachCoordinatorWithoutMixingRoots() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = try HermesReviewDatabase(file: directory.appendingPathComponent(".hermes/state.db"))
        let profile = try HermesReviewDatabase(file: directory.appendingPathComponent(".hermes/profiles/work/state.db"))
        let custom = try HermesReviewDatabase(file: directory.appendingPathComponent("custom/state.db"))
        try profile.execute("UPDATE sessions SET id='profile'")
        try custom.execute("UPDATE sessions SET id='custom'")

        let defaults = await UsageCollectionCoordinator(environment: FakeEnvironment([:]), home: directory).collect(since: .distantPast)
        let configured = await UsageCollectionCoordinator(
            environment: FakeEnvironment(["HERMES_HOME": custom.file.deletingLastPathComponent().path]), home: directory
        ).collect(since: .distantPast)
        let selectedProfile = await UsageCollectionCoordinator(
            environment: FakeEnvironment(["HERMES_HOME": profile.file.deletingLastPathComponent().path]), home: directory
        ).collect(since: .distantPast)

        XCTAssertEqual(Set(defaults?.records.map(\.sessionID) ?? []), ["s", "profile"])
        XCTAssertEqual(configured?.records.map(\.sessionID), ["custom"])
        XCTAssertEqual(selectedProfile?.records.map(\.sessionID), ["profile"])
        XCTAssertEqual(defaults?.readFailureCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: main.file.path))
    }

    func testRootDatabaseSymlinkIsCollectedForDefaultAndConfiguredHome() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try HermesReviewDatabase(file: directory.appendingPathComponent("external/ledger"))
        let defaultHome = directory.appendingPathComponent(".hermes")
        let customHome = directory.appendingPathComponent("custom")
        for home in [defaultHome, customHome] {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("state.db"), withDestinationURL: database.file)
        }
        for environment in [FakeEnvironment([:]), FakeEnvironment(["HERMES_HOME": customHome.path])] {
            let collected = await UsageCollectionCoordinator(environment: environment, home: directory).collect(since: .distantPast)
            let collection = try XCTUnwrap(collected)
            XCTAssertEqual(collection.records.filter { $0.sourceID == "hermes" }.map(\.totalTokens), [1100])
            XCTAssertEqual(collection.readFailureCount, 0)
        }
    }

    func testWALUpdatesAreRereadAndBrokenSchemaIsReported() async throws {
        let database = try HermesReviewDatabase()
        let first = try await database.collect()
        let before = try Data(contentsOf: database.file)
        try database.execute("UPDATE sessions SET input_tokens=1200")

        let second = try await database.collect()

        XCTAssertEqual(first.records.first?.totalTokens, 1100)
        XCTAssertEqual(second.records.first?.totalTokens, 1300)
        XCTAssertEqual(try Data(contentsOf: database.file), before)
        try database.execute("DROP TABLE sessions")
        let broken = try await database.collect()
        XCTAssertEqual(broken.readFailureCount, 1)
        XCTAssertTrue(broken.records.isEmpty)
    }

    func testSymlinkedHomeFindsDirectProfilesWithoutIncludingNestedStores() async throws {
        let directory = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realHome = directory.appendingPathComponent("real-home")
        let alias = directory.appendingPathComponent("home-alias")
        let profile = try HermesReviewDatabase(file: realHome.appendingPathComponent(".hermes/profiles/work/state.db"))
        let nested = try HermesReviewDatabase(file: realHome.appendingPathComponent(".hermes/profiles/work/nested/state.db"))
        try profile.execute("UPDATE sessions SET id='profile'")
        try nested.execute("UPDATE sessions SET id='nested'")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realHome)

        let collected = await UsageCollectionCoordinator(environment: FakeEnvironment([:]), home: alias).collect(since: .distantPast)
        let collection = try XCTUnwrap(collected)

        XCTAssertEqual(collection.records.map(\.sessionID), ["profile"])
        XCTAssertEqual(collection.records.first?.filePath, profile.file.resolvingSymlinksInPath().path)
        XCTAssertEqual(collection.readFailureCount, 0)
    }
}

@MainActor
private final class HermesReviewDatabase {
    let file: URL
    private let ownedDirectory: URL?
    private var handle: OpaquePointer?

    init(file: URL? = nil) throws {
        if let file {
            self.file = file
            ownedDirectory = nil
        } else {
            let directory = try UsageRecordFixture.temporaryDirectory()
            self.file = directory.appendingPathComponent("state.db")
            ownedDirectory = directory
        }
        try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(self.file.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try execute("""
        PRAGMA journal_mode=WAL;
        PRAGMA wal_autocheckpoint=0;
        CREATE TABLE sessions(id TEXT,model TEXT,billing_provider TEXT,started_at REAL,ended_at REAL,
            input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,
            estimated_cost_usd REAL,actual_cost_usd REAL,cost_status TEXT,billing_base_url TEXT,billing_mode TEXT,model_config TEXT);
        INSERT INTO sessions VALUES('s','claude-sonnet-4-6','anthropic',1793494800,1793494810,1000,100,0,0,0,0,0,'unknown','','',NULL);
        CREATE TABLE session_model_usage(session_id TEXT,model TEXT,billing_provider TEXT,billing_base_url TEXT,billing_mode TEXT,
            task TEXT,first_seen REAL,last_seen REAL,input_tokens INTEGER,output_tokens INTEGER,cache_read_tokens INTEGER,
            cache_write_tokens INTEGER,reasoning_tokens INTEGER,estimated_cost_usd REAL,actual_cost_usd REAL,cost_status TEXT);
        """)
    }

    func model(input: Int, output: Int, task: String = "", cost: Double = 0) throws {
        try execute("""
        INSERT INTO session_model_usage VALUES('s','claude-sonnet-4-6','anthropic','','','\(task)',1793494800,1793494810,
            \(input),\(output),0,0,0,\(cost),0,'estimated');
        """)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.coderInvalidValue) }
    }

    func collect(since: Date = .distantPast) async throws -> UsageCollection {
        let collector = UsageSQLiteCollector(sourceID: "hermes", roots: [file], includeFile: { _ in true }, parse: HermesUsageParser.database)
        let result = await UsageCollectionCoordinator(collectors: [collector]).collect(since: since)
        return try XCTUnwrap(result)
    }

    isolated deinit {
        sqlite3_close(handle)
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
    }
}
