import SQLite3
import XCTest
@testable import Egasu

@MainActor
final class KiloCollectionReviewTests: XCTestCase {
    func testRoutedModelKeepsBillingProviderSeparateFromUpstream() async throws {
        let database = try KiloReviewDatabase()
        try database.step("auto", provider: "kilo", model: "auto", fields: [
            "model": ["providerID": "anthropic", "modelID": "tiered-model"]
        ])

        let result = try await collect(database)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(record.providerID, "kilo")
        XCTAssertEqual(record.model, "auto")
        XCTAssertEqual(record.responseModel, "tiered-model")
        XCTAssertEqual(record.upstreamProvider, "anthropic")
        XCTAssertEqual(record.totalTokens, 120)
        let claudeScan = try XCTUnwrap(UsageHistoryBuilder.scan(
            result, providerID: "claude", since: .distantPast, pricing: pricing
        ))
        XCTAssertTrue(claudeScan.series.daily.isEmpty)
    }

    func testForkCopiesUsePersistedResponseIDsAndKeepNewCalls() async throws {
        for field in ["generationID", "vercelID"] {
            let database = try KiloReviewDatabase()
            try database.step("original", session: "original", cost: 0.1, fields: [field: "request-1"])
            try database.step("copy", session: "fork", cost: 0, fields: [field: "request-1"])
            try database.step("next", session: "fork", cost: 0.2, fields: [field: "request-2"])

            let result = try await collect(database)
            XCTAssertEqual(result.records.count, 2, field)
            XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 240, field)
            XCTAssertEqual(result.records.reduce(0) { $0 + ($1.recordedCostUSD ?? 0) }, 0.3, accuracy: 1e-9, field)
            XCTAssertTrue(result.records.allSatisfy { $0.issues.isEmpty }, field)
        }
    }

    func testGenerationIDTakesPrecedenceAndVercelIDsHaveTheirOwnNamespace() async throws {
        let database = try KiloReviewDatabase()
        try database.step("first", fields: ["generationID": "generation-1", "vercelID": "same-header"])
        try database.step("second", fields: ["generationID": "generation-2", "vercelID": "same-header"])
        try database.step("generation", fields: ["generationID": "header-only"])
        try database.step("header", fields: ["vercelID": "header-only"])

        let result = try await collect(database)
        XCTAssertEqual(result.records.count, 4)
        XCTAssertEqual(Set(result.records.compactMap(\.responseID)), [
            "generation-1", "generation-2", "header-only", "kilo:vercel:header-only"
        ])
    }

    func testIndependentZeroCostCallsWithoutResponseIDsAreRetained() async throws {
        let database = try KiloReviewDatabase()
        try database.step("first", session: "original", cost: 0)
        try database.step("second", session: "other", cost: 0)

        let result = try await collect(database)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 240)
        XCTAssertTrue(result.records.allSatisfy { $0.responseID == nil && $0.issues.isEmpty })
        XCTAssertTrue(result.records.allSatisfy { $0.recordedCostUSD == 0 })
    }

    func testEstimatedZeroKeepsTokensAndLeavesUnknownPriceIncomplete() async throws {
        let database = try KiloReviewDatabase()
        try database.step("unknown", model: "missing-rates", cost: 0)
        let result = try await collect(database)
        let record = try XCTUnwrap(result.records.first)
        XCTAssertEqual(record.costOrigin, .estimated)
        XCTAssertEqual(record.recordedCostUSD, 0)
        XCTAssertTrue(record.zeroCostIsUnknown)

        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        let day = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(day.totalTokens, 120)
        XCTAssertNil(day.costUSD)
        XCTAssertEqual(scan.unknownModelsByDay[day.date], ["missing-rates"])
    }

    func testEstimatedZeroUsesRoutedModelPriceAndPositiveCostStillWins() async throws {
        let database = try KiloReviewDatabase()
        let fields: [String: Any] = ["model": ["providerID": "anthropic", "modelID": "tiered-model"]]
        try database.step("estimated", model: "requested-unpriced", cost: 0, fields: fields)
        try database.step("recorded", model: "requested-unpriced", cost: 0.3, fields: fields)
        let result = try await collect(database)

        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: pricing))
        let day = try XCTUnwrap(scan.series.daily.first)
        XCTAssertEqual(day.totalTokens, 240)
        XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.30002, accuracy: 1e-9)
        XCTAssertTrue(scan.unknownModelsByDay.isEmpty)
    }

    func testSequencedV2StepUsesRequestLongContextPricing() async throws {
        let costs: [Double?] = [nil, 0]
        for cost in costs {
            let database = try KiloReviewDatabase()
            try database.assistant("long-request", seq: 1, input: 100_001, output: 1_000, cost: cost)
            let result = try await collect(database)
            XCTAssertEqual(result.records.first?.granularity, .request)

            let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: pricing))
            let day = try XCTUnwrap(scan.series.daily.first)
            XCTAssertEqual(day.totalTokens, 101_001)
            XCTAssertEqual(try XCTUnwrap(day.costUSD), 0.0525005, accuracy: 1e-9)
        }
    }

    func testUnsequencedV2CompatibilityRowKeepsAggregatePricing() async throws {
        let database = try KiloReviewDatabase()
        try database.assistant("legacy-row", seq: nil, input: 100_001, output: 1_000, cost: nil)
        let result = try await collect(database)
        XCTAssertEqual(result.records.first?.granularity, .aggregate)

        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: pricing))
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.0105001, accuracy: 1e-9)
    }

    func testV1MessageRollupStaysUnresolvedWhenV2ContainsTheSameMessage() async throws {
        let database = try KiloReviewDatabase()
        try database.message("rollup", cost: 0.5)
        try database.assistant("rollup", seq: 1, cost: 0.5)
        let result = try await collect(database)
        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.granularity, .aggregate)
        XCTAssertTrue(result.records.first?.issues.contains(.unresolvedMirror) == true)

        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: pricing))
        XCTAssertTrue(scan.series.daily.isEmpty)
        XCTAssertEqual(scan.rejectedMetadataRows, 1)
    }

    func testMixedSessionKeepsV2RawRowsUnresolvedAndV2OnlySessionStillCounts() async throws {
        let database = try KiloReviewDatabase()
        try database.step("v1", session: "mixed", cost: 0.2)
        try database.assistant("different-v2-id", seq: 1, cost: 0.2)
        try database.assistant("v2-only-call-in-mixed-session", seq: 2, cost: 0.3)
        try database.assistant("v1", seq: 3, cost: 0.2)
        try database.assistant("independent-v2-session", seq: 4, cost: 0.4)
        try database.execute("UPDATE session_message SET session_id='mixed' WHERE id!='independent-v2-session'")

        let result = try await collect(database)
        XCTAssertEqual(result.records.count, 5)
        let unresolved = result.records.filter { $0.issues.contains(.unresolvedMirror) }
        XCTAssertEqual(Set(unresolved.compactMap(\.id)), ["different-v2-id", "v2-only-call-in-mixed-session", "v1"])
        XCTAssertTrue(unresolved.allSatisfy { $0.sessionID == "mixed" && $0.totalTokens == 120 })
        XCTAssertEqual(unresolved.compactMap(\.recordedCostUSD).reduce(0, +), 0.7, accuracy: 1e-9)
        XCTAssertTrue(result.records.first { $0.id == "part-v1" }?.issues.isEmpty == true)
        XCTAssertTrue(result.records.first { $0.id == "independent-v2-session" }?.issues.isEmpty == true)
        let scan = try XCTUnwrap(UsageHistoryBuilder.scan(result, providerID: "claude", since: .distantPast, pricing: .empty))
        XCTAssertEqual(scan.series.daily.first?.totalTokens, 240)
        XCTAssertEqual(try XCTUnwrap(scan.series.daily.first?.costUSD), 0.6, accuracy: 1e-9)
        XCTAssertEqual(scan.rejectedMetadataRows, 3)
    }

    func testV1StepsInAnotherDatabaseDoNotSuppressV2Session() async throws {
        let first = try KiloReviewDatabase()
        let second = try KiloReviewDatabase()
        try first.step("v1", session: "same-session", cost: 0.1)
        try second.assistant("v2", seq: 1, cost: 0.2)
        try second.execute("UPDATE session_message SET session_id='same-session'")
        let collector = UsageSQLiteCollector(
            sourceID: "kilo", roots: [first.file, second.file], includeFile: { _ in true }, parse: KiloUsageParser.database
        )
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)

        XCTAssertEqual(result.readFailureCount, 0)
        XCTAssertEqual(result.records.count, 2)
        XCTAssertTrue(result.records.allSatisfy { $0.issues.isEmpty })
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 240)
    }

    func testLegacyEstimatedZeroPreservesInclusiveTokenBuckets() throws {
        let usage: [String: Any] = [
            "tokensIn": 100, "tokensOut": 20, "cacheReads": 30, "cacheWrites": 10,
            "cost": 0, "apiProtocol": "openai", "modelInfo": ["id": "tiered-model"]
        ]
        let encodedUsage = String(decoding: try JSONSerialization.data(withJSONObject: usage), as: UTF8.self)
        let messages: [[String: Any]] = [[
            "type": "say", "say": "api_req_started", "ts": 1_793_494_800_000, "text": encodedUsage
        ]]
        let data = try JSONSerialization.data(withJSONObject: messages)
        let result = try KiloUsageParser.legacy(data, path: "/fixture/task/ui_messages.json")
        let record = try XCTUnwrap(result.first)
        XCTAssertEqual(record.tokens?.input, 60)
        XCTAssertEqual(record.tokens?.cacheRead, 30)
        XCTAssertEqual(record.tokens?.cacheWrite5m, 10)
        XCTAssertEqual(record.totalTokens, 120)
        XCTAssertEqual(record.recordedCostUSD, 0)
        XCTAssertEqual(record.costOrigin, .estimated)
        XCTAssertTrue(record.zeroCostIsUnknown)
        XCTAssertNil(record.providerID)
    }

    func testRegistryAcceptsAbsoluteAndRelativeDatabaseFilesWithoutDBExtension() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let data = root.appendingPathComponent("xdg")
        let kilo = data.appendingPathComponent("kilo")
        let fallback = try KiloReviewDatabase(file: kilo.appendingPathComponent("kilo.db"))
        try fallback.step("fallback", input: 999)
        let cases = [
            ("relative.sqlite", kilo.appendingPathComponent("relative.sqlite")),
            ("nested/ledger", kilo.appendingPathComponent("nested/ledger")),
            (root.appendingPathComponent("absolute.sqlite").path, root.appendingPathComponent("absolute.sqlite")),
            (root.appendingPathComponent("absolute-ledger").path, root.appendingPathComponent("absolute-ledger"))
        ]

        for (index, entry) in cases.enumerated() {
            let (configured, file) = entry
            let database = try KiloReviewDatabase(file: file)
            try database.step("selected-\(index)", input: 100 + index)
            let result = try await registry(home: home, environment: ["XDG_DATA_HOME": data.path, "KILO_DB": configured])
            XCTAssertEqual(result.records.count, 1, configured)
            XCTAssertEqual(result.records.first?.totalTokens, 120 + index, configured)
            XCTAssertEqual(result.records.first?.filePath, file.resolvingSymlinksInPath().path, configured)
            XCTAssertEqual(result.sources.first { $0.sourceID == "kilo" }?.completedStores, 1, configured)
        }
    }

    func testRegistryResolvesExplicitDatabaseAndParentDirectorySymlinks() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real")
        let database = try KiloReviewDatabase(file: real.appendingPathComponent("custom.sqlite"))
        try database.step("linked")
        let linkedFile = root.appendingPathComponent("linked.db")
        let linkedDirectory = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: linkedFile, withDestinationURL: database.file)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: real)

        for configured in [linkedFile, linkedDirectory.appendingPathComponent("custom.sqlite")] {
            let result = try await registry(home: root.appendingPathComponent("home"), environment: ["KILO_DB": configured.path])
            XCTAssertEqual(result.records.count, 1)
            XCTAssertEqual(result.records.first?.filePath, database.file.resolvingSymlinksInPath().path)
            XCTAssertEqual(result.sources.first { $0.sourceID == "kilo" }?.completedStores, 1)
        }
    }

    func testMemoryDatabaseOverrideDoesNotFallBackToDefaultDiskDatabase() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("xdg")
        let database = try KiloReviewDatabase(file: data.appendingPathComponent("kilo/kilo.db"))
        try database.step("disk")
        let result = try await registry(
            home: root.appendingPathComponent("home"), environment: ["XDG_DATA_HOME": data.path, "KILO_DB": ":memory:"])
        XCTAssertTrue(result.records.isEmpty)
        XCTAssertEqual(result.sources.first { $0.sourceID == "kilo" }?.completedStores, 0)
        XCTAssertEqual(result.readFailureCount, 0)
    }

    func testDefaultRegistrySelectsChannelsAndReadsCanonicalDatabaseOnce() async throws {
        let root = try UsageRecordFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("xdg")
        let kilo = data.appendingPathComponent("kilo")
        for (name, input) in [("kilo.db", 100), ("kilo-dev.db", 200), ("opencode-old.db", 300), ("opencode-dev.db", 900), ("unrelated.db", 999)] {
            let database = try KiloReviewDatabase(file: kilo.appendingPathComponent(name))
            try database.step(name, input: input, output: 0)
        }
        try FileManager.default.createSymbolicLink(at: kilo.appendingPathComponent("kilo-copy.db"), withDestinationURL: kilo.appendingPathComponent("kilo.db"))

        let result = try await registry(home: root.appendingPathComponent("home"), environment: ["XDG_DATA_HOME": data.path])
        XCTAssertEqual(result.records.count, 3)
        XCTAssertEqual(result.records.reduce(0) { $0 + $1.totalTokens }, 600)
        XCTAssertEqual(result.sources.first { $0.sourceID == "kilo" }?.completedStores, 3)
    }

    private var pricing: ModelPricing {
        let rates = ModelRates(
            inputPerMillion: 0.1, outputPerMillion: 0.5, cacheWritePerMillion: 0.125, cacheReadPerMillion: 0.01,
            inputAbove200kPerMillion: 0.5, outputAbove200kPerMillion: 2.5,
            longContextThresholdTokens: 100_000)
        return ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(entries: ["tiered-model": rates]), secondary: PricingCatalog())
    }

    private func collect(_ database: KiloReviewDatabase) async throws -> UsageCollection {
        let collector = UsageSQLiteCollector(sourceID: "kilo", roots: [database.file], includeFile: { _ in true }, parse: KiloUsageParser.database)
        let collected = await UsageCollectionCoordinator(collectors: [collector]).collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.readFailureCount, 0)
        return result
    }

    private func registry(home: URL, environment: [String: String]) async throws -> UsageCollection {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let coordinator = UsageCollectionCoordinator(environment: FakeEnvironment(environment), home: home)
        let collected = await coordinator.collect(since: .distantPast)
        let result = try XCTUnwrap(collected)
        XCTAssertEqual(result.readFailureCount, 0)
        return result
    }
}

@MainActor
final class KiloReviewDatabase {
    let file: URL
    private let ownedDirectory: URL?
    private var handle: OpaquePointer?
    private let timestamp = 1_793_494_800_000

    init(file: URL? = nil) throws {
        if let file {
            self.file = file
            ownedDirectory = nil
        } else {
            let directory = try UsageRecordFixture.temporaryDirectory()
            self.file = directory.appendingPathComponent("usage.db")
            ownedDirectory = directory
        }
        try FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(self.file.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try execute("""
        CREATE TABLE message(id TEXT PRIMARY KEY,session_id TEXT,time_created INTEGER,data TEXT);
        CREATE TABLE part(id TEXT PRIMARY KEY,message_id TEXT,session_id TEXT,time_created INTEGER,data TEXT);
        CREATE TABLE session_message(id TEXT PRIMARY KEY,session_id TEXT,type TEXT,seq INTEGER,time_created INTEGER,data TEXT);
        """)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.coderInvalidValue) }
    }

    func message(
        _ id: String, session: String? = nil, provider: String = "anthropic", model: String = "tiered-model",
        input: Int = 100, output: Int = 20, cost: Double = 0.1
    ) throws {
        let data: [String: Any] = [
            "role": "assistant", "providerID": provider, "modelID": model, "cost": cost,
            "time": ["created": timestamp], "tokens": tokens(input: input, output: output)
        ]
        try execute("INSERT INTO message VALUES(\(text(id)),\(text(session ?? id)),\(timestamp),\(try json(data)))")
    }

    func step(
        _ id: String, session: String? = nil, provider: String = "anthropic", model: String = "tiered-model",
        input: Int = 100, output: Int = 20, cost: Double = 0.1, fields: [String: Any] = [:]
    ) throws {
        try message(id, session: session, provider: provider, model: model, input: input, output: output, cost: cost)
        var data: [String: Any] = [
            "type": "step-finish", "reason": "stop", "cost": cost,
            "time": ["start": timestamp, "end": timestamp + 1000], "tokens": tokens(input: input, output: output)
        ]
        data.merge(fields) { _, new in new }
        try execute("INSERT INTO part VALUES(\(text("part-" + id)),\(text(id)),\(text(session ?? id)),\(timestamp),\(try json(data)))")
    }

    func assistant(_ id: String, seq: Int?, input: Int = 100, output: Int = 20, cost: Double?) throws {
        var data: [String: Any] = [
            "model": ["providerID": "anthropic", "id": "tiered-model"], "time": ["created": timestamp, "completed": timestamp + 1000],
            "tokens": tokens(input: input, output: output)
        ]
        if let cost { data["cost"] = cost }
        try execute("INSERT INTO session_message VALUES(\(text(id)),\(text(id)),'assistant',\(seq.map(String.init) ?? "NULL"),\(timestamp),\(try json(data)))")
    }

    private func tokens(input: Int, output: Int) -> [String: Any] {
        ["input": input, "output": output, "reasoning": 0, "cache": ["read": 0, "write": 0]]
    }

    private func json(_ value: [String: Any]) throws -> String {
        text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    private func text(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

    isolated deinit {
        sqlite3_close(handle)
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
    }
}
