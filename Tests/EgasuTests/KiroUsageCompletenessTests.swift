import Foundation
import SQLite3
import XCTest
@testable import Egasu

@MainActor
final class KiroUsageCompletenessTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!

    func testEmptyV3MeteringKeepsTokensWhileExplicitZeroKeepsZeroCost() throws {
        let cases: [(entries: [[String: Any]], cost: Double?)] = [([], nil), ([["unit": "credit", "usage": 0]], 0)]
        for entry in cases {
            let parsed = try KiroUsageScanner.parse(v3History(credits: entry.entries))
            let record = try XCTUnwrap(parsed.records.first)
            let result = KiroUsageScanner.aggregate(parsed, now: now)
            let lines = result.totalSpendLines(now: now)

            XCTAssertEqual(parsed.invalidRows, 0)
            XCTAssertEqual(record.tokens, 4)
            XCTAssertEqual(record.costUSD, entry.cost)
            XCTAssertEqual(value(lines, kind: .count), 4)
            XCTAssertEqual(value(lines, kind: .dollars), entry.cost)
            XCTAssertEqual(result.warnings.count, entry.cost == nil ? 1 : 0)
        }
    }

    func testEmptyV3MeteringWithoutSavedResponseDoesNotInventUsage() throws {
        let parsed = try KiroUsageScanner.parse(v3History(credits: [], response: false))
        let result = KiroUsageScanner.aggregate(parsed, now: now)

        XCTAssertTrue(parsed.records.isEmpty)
        XCTAssertEqual(parsed.invalidRows, 0)
        XCTAssertTrue(result.daily.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnreportedV3MeteringOmitsMixedPeriodCost() throws {
        let data = try v3History(turn: "paid", credits: [["unit": "credit", "usage": 1]])
            + v3History(turn: "unreported", credits: [])
        let parsed = try KiroUsageScanner.parse(data)
        let result = KiroUsageScanner.aggregate(parsed, now: now)
        let lines = result.totalSpendLines(now: now)

        XCTAssertEqual(parsed.records.count, 2)
        XCTAssertEqual(result.daily.first?.tokens, 12)
        XCTAssertTrue(result.daily.first?.missingCost == true)
        XCTAssertEqual(value(lines, kind: .count), 12)
        XCTAssertNil(value(lines, kind: .dollars))
        XCTAssertNil(value(lines, label: "Last 30 Days", kind: .dollars))
        XCTAssertEqual(result.invalidRows, 0)
    }

    func testEmptyLegacyMeteringKeepsMeasuredTokensAndDoesNotCreateUnattributedCredits() throws {
        let fixture = try KiroCompletenessFixture()
        let cases: [(entries: [[String: Any]], cost: Double?)] = [([], nil), ([["unit": "credit", "value": 0]], 0)]
        for entry in cases {
            let session = try JSONSerialization.data(withJSONObject: [
                "session_id": "legacy", "session_state": ["conversation_metadata": ["user_turn_metadatas": [[
                    "message_ids": ["message"], "end_timestamp": now.timeIntervalSince1970 - 1,
                    "input_token_count": 10, "output_token_count": 5, "metering_usage": entry.entries
                ]]]]
            ])
            let records = try KiroLegacyUsageParser.session(session, path: "fixture/session.json")
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records.first?.totalTokens, 15)
            XCTAssertEqual(records.first?.recordedCostUSD, entry.cost)
            XCTAssertTrue(records.first?.issues.isEmpty == true)

            var conversation = legacyConversation(credits: entry.entries)
            conversation["user_turn_metadata"] = ["usage_info": [[String: Any]]()]
            try fixture.replaceConversation(conversation)
            let databaseRecords = try KiroLegacyUsageParser.database(UsageDatabase(path: fixture.database.path), path: fixture.database.path)
            XCTAssertEqual(databaseRecords.count, 1)
            XCTAssertEqual(databaseRecords.first?.totalTokens, 15)
            XCTAssertEqual(databaseRecords.first?.recordedCostUSD, entry.cost)
            XCTAssertTrue(databaseRecords.first?.issues.isEmpty == true)
        }
    }

    func testLegacyInvalidNumbersRemainVisibleWithoutAnotherValidMeasurement() async throws {
        let fixture = try KiroCompletenessFixture()
        let turns: [[String: Any]] = [
            ["request_metadata": ["request_start_timestamp_ms": now.timeIntervalSince1970 * 1_000,
                                  "token_usage": ["input_tokens": -1, "output_tokens": 5]]],
            ["request_metadata": ["request_start_timestamp_ms": now.timeIntervalSince1970 * 1_000],
             "user_turn_metadata": ["usage_info": [["unit": "credit", "value": -1]]]]
        ]
        for turn in turns {
            try fixture.replaceConversation(["history": [turn]])
            let records = try KiroLegacyUsageParser.database(UsageDatabase(path: fixture.database.path), path: fixture.database.path)
            XCTAssertEqual(records.count, 1)
            XCTAssertTrue(records.first?.issues.contains(.invalidNumbers) == true)
            XCTAssertNil(records.first?.tokens)
            XCTAssertNil(records.first?.recordedCostUSD)

            let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
            let result = try await scanner.scan(now: now)
            XCTAssertEqual(result?.invalidRows, 1)
            XCTAssertTrue(result?.daily.isEmpty == true)
            let snapshot = await provider(scanner: scanner, http: FakeHTTPClient(response: quotaResponse())).refresh()
            XCTAssertNil(snapshot.totalSpendLines)
            XCTAssertEqual(snapshot.isDegraded, true)
        }
    }

    func testLegacyMetadataWithoutUsageDoesNotInventAnInvalidRecord() throws {
        let fixture = try KiroCompletenessFixture()
        let metadataRows: [[String: Any]] = [[:], ["request_start_timestamp_ms": now.timeIntervalSince1970 * 1_000]]
        for metadata in metadataRows {
            try fixture.replaceConversation(["history": [["request_metadata": metadata]]])
            let records = try KiroLegacyUsageParser.database(UsageDatabase(path: fixture.database.path), path: fixture.database.path)
            XCTAssertTrue(records.isEmpty)
        }
    }

    func testEmptyLegacyMeteringReachesNativeStatisticsWithoutZeroCost() async throws {
        let fixture = try KiroCompletenessFixture()
        try fixture.replaceConversation(legacyConversation(credits: []))
        let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)

        let result = try await scanner.scan(now: now)

        XCTAssertEqual(result?.daily.first?.tokens, 15)
        XCTAssertTrue(result?.daily.first?.missingCost == true)
        XCTAssertEqual(result?.invalidRows, 0)
        XCTAssertEqual(value(result?.totalSpendLines(now: now) ?? [], kind: .count), 15)
        XCTAssertNil(value(result?.totalSpendLines(now: now) ?? [], kind: .dollars))
    }

    func testMissingObservedV3StoreRetainsSameDayTotalsWithEmptyLegacyDatabase() async throws {
        for emptyHistory in [false, true] {
            for quotaFails in [false, true] {
                let fixture = try KiroCompletenessFixture()
                try fixture.writeV3(emptyHistory ? Data() : v3History())
                let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
                let http = FakeHTTPClient(response: quotaResponse())
                let runtime = provider(scanner: scanner, http: http)
                let (store, defaults, suite) = self.store(runtime)
                defer { defaults.removePersistentDomain(forName: suite) }
                await store.refreshAll(force: true)
                let previous = try XCTUnwrap(store.localSnapshots["kiro"]?.totalSpendLines)
                XCTAssertEqual(previous.isEmpty, emptyHistory)
                if !emptyHistory { XCTAssertEqual(value(previous, kind: .count), 4) }
                try FileManager.default.removeItem(at: fixture.sessions)
                if quotaFails { http.response = HTTPResponse(statusCode: 500, headers: [:], body: Data()) }

                await store.refreshAll(force: true)

                let retained = store.localSnapshots["kiro"]
                XCTAssertEqual(retained?.totalSpendLines, previous)
                XCTAssertTrue(retained?.warning?.contains("Kiro CLI usage history could not be read") == true)
                XCTAssertTrue(retained?.isDegraded == true)
                XCTAssertEqual(store.providerErrors["kiro"] != nil, quotaFails)

                try FileManager.default.createDirectory(at: fixture.sessions, withIntermediateDirectories: true)
                http.response = quotaResponse()
                await store.refreshAll(force: true)
                XCTAssertEqual(store.localSnapshots["kiro"]?.totalSpendLines, [])
                XCTAssertNil(store.localSnapshots["kiro"]?.warning)
            }
        }
    }

    func testLegacyOnlyConfirmedEmptyDatabaseClearsPriorStatistics() async throws {
        let fixture = try KiroCompletenessFixture()
        try fixture.replaceConversation(legacyConversation())
        let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
        let runtime = provider(scanner: scanner, http: FakeHTTPClient(response: quotaResponse()))
        let (store, defaults, suite) = self.store(runtime)
        defer { defaults.removePersistentDomain(forName: suite) }
        await store.refreshAll(force: true)
        XCTAssertEqual(value(store.localSnapshots["kiro"]?.totalSpendLines ?? [], kind: .count), 15)
        try fixture.replaceConversation(nil)

        await store.refreshAll(force: true)

        XCTAssertEqual(store.localSnapshots["kiro"]?.totalSpendLines, [])
        XCTAssertNil(store.localSnapshots["kiro"]?.warning)
        let fresh = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
        let empty = try await fresh.scan(now: now)
        XCTAssertEqual(empty?.totalSpendLines(now: now), [])
        XCTAssertTrue(empty?.warnings.isEmpty == true)
    }

    func testMissingObservedV3StoreKeepsReadableLegacyUsageWithWarning() async throws {
        let fixture = try KiroCompletenessFixture()
        try fixture.writeV3(v3History())
        try fixture.replaceConversation(legacyConversation())
        let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
        let runtime = provider(scanner: scanner, http: FakeHTTPClient(response: quotaResponse()))
        let initial = await runtime.refresh()
        XCTAssertEqual(value(initial.totalSpendLines ?? [], kind: .count), 19)
        try FileManager.default.removeItem(at: fixture.sessions)

        let partial = await runtime.refresh()

        XCTAssertEqual(value(partial.totalSpendLines ?? [], kind: .count), 15)
        XCTAssertEqual(value(partial.totalSpendLines ?? [], kind: .dollars), 0.04)
        XCTAssertTrue(partial.warning?.contains("Some local usage files could not be read") == true)
        XCTAssertTrue(partial.isDegraded == true)
        XCTAssertNil(partial.errorCategory)
    }

    func testDifferentResolvedProfileDoesNotInheritPreviousMissingStoreState() async throws {
        let fixture = try KiroCompletenessFixture()
        let first = fixture.home.appendingPathComponent("profile-a")
        let second = fixture.home.appendingPathComponent("profile-b")
        let alias = fixture.home.appendingPathComponent("selected-profile")
        try fixture.writeV3(v3History(), profile: first)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: first)
        let scanner = KiroUsageScanner(environment: FakeEnvironment(["KIRO_HOME": alias.path]), homeDirectory: fixture.home)
        let initial = try await scanner.scan(now: now)
        XCTAssertEqual(initial?.daily.first?.tokens, 4)
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: second)

        let selected = try await scanner.scan(now: now)

        XCTAssertEqual(selected?.totalSpendLines(now: now), [])
        XCTAssertTrue(selected?.warnings.isEmpty == true)
    }

    private func v3History(
        turn: String = "turn", credits: [[String: Any]] = [["unit": "credit", "usage": 1]], response: Bool = true
    ) throws -> Data {
        var payloads: [[String: Any]] = [
            ["type": "user", "content": "abcdefgh"], ["type": "turn_start", "executionId": turn]
        ]
        if response { payloads.append(["type": "assistant", "content": "abcdefgh", "executionId": turn]) }
        payloads.append(["type": "usage_summary", "executionId": turn, "promptTurnSummaries": credits])
        return try payloads.enumerated().reduce(into: Data()) { data, entry in
            data += try JSONSerialization.data(withJSONObject: [
                "id": "\(turn)-\(entry.offset)", "timestamp": EgasuISO8601.string(from: now.addingTimeInterval(-1)),
                "payload": entry.element
            ]) + Data([0x0A])
        }
    }

    func testZeroTokenNilCostDoesNotHideValidDayCost() {
        let date = now.addingTimeInterval(-1)
        let parsed = KiroUsageScanner.Parsed(records: [
            .init(id: "cost", timestamp: date, costUSD: 0.5, tokens: 10),
            .init(id: "empty", timestamp: date, costUSD: nil, tokens: 0),
            .init(id: "zero", timestamp: date, costUSD: 0, tokens: 0)
        ])
        let result = KiroUsageScanner.aggregate(parsed, now: now)
        XCTAssertEqual(result.daily.first?.costUSD, 0.5)
        XCTAssertEqual(result.daily.first?.missingCost, false)
        XCTAssertEqual(value(result.totalSpendLines(now: now), kind: .dollars), 0.5)
    }

    func testMalformedSupportedV2FieldsAreIncompleteWhileAbsentAndEmptyFieldsStayEmpty() async throws {
        let fixture = try KiroCompletenessFixture()
        let path = fixture.home.appendingPathComponent(".kiro/sessions/cli/fixture.json")
        for session in [
            #"{"session_id":"s","session_state":"broken"}"#,
            #"{"session_id":"s","session_state":{"conversation_metadata":"broken"}}"#,
            #"{"session_id":"s","session_state":{"conversation_metadata":{"user_turn_metadatas":"broken"}}}"#
        ] {
            let records = try KiroLegacyUsageParser.session(Data(session.utf8), path: path.path)
            XCTAssertEqual(records.count, 1)
            XCTAssertTrue(records[0].issues.contains(.invalidMetadata))
        }
        for session in [
            #"{"session_id":"s"}"#,
            #"{"session_id":"s","session_state":{"conversation_metadata":{"user_turn_metadatas":[]}}}"#
        ] {
            XCTAssertTrue(try KiroLegacyUsageParser.session(Data(session.utf8), path: path.path).isEmpty)
        }
        try UsageRecordFixture.write(#"{"session_id":"s","session_state":{"conversation_metadata":{"user_turn_metadatas":"broken"}}}"#,
                                     to: path)
        let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
        let fileScan = try await scanner.scan(now: now)
        XCTAssertEqual(fileScan?.invalidRows, 1)
        XCTAssertTrue(fileScan?.daily.isEmpty == true)
        try FileManager.default.removeItem(at: path)
        try fixture.replaceConversation(["history": "broken"])
        let databaseRecords = try KiroLegacyUsageParser.database(UsageDatabase(path: fixture.database.path), path: fixture.database.path)
        XCTAssertEqual(databaseRecords.count, 1)
        XCTAssertTrue(databaseRecords[0].issues.contains(.invalidMetadata))
        let databaseScan = try await KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home).scan(now: now)
        XCTAssertEqual(databaseScan?.invalidRows, 1)
        try fixture.replaceConversation(["history": [[String: Any]]()])
        XCTAssertTrue(try KiroLegacyUsageParser.database(UsageDatabase(path: fixture.database.path), path: fixture.database.path).isEmpty)
    }

    func testCancelledLegacySessionParsingThrows() async throws {
        let row = #"{"session_state":{"conversation_metadata":{"user_turn_metadatas":[{}]}}}"#
        let task = Task.detached { () throws -> [UsageRecord] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try KiroLegacyUsageParser.session(Data(row.utf8), path: "/fixture/session.json")
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation should propagate")
        } catch is CancellationError {
        }
    }

    func testMalformedLegacyDatabaseRowPreservesOtherConversations() async throws {
        let fixture = try KiroCompletenessFixture()
        try fixture.replaceConversation(legacyConversation())
        try fixture.addMalformedConversation()
        let records = try KiroLegacyUsageParser.database(UsageDatabase(path: fixture.database.path), path: fixture.database.path)
        XCTAssertEqual(records.filter { $0.issues.isEmpty }.first?.totalTokens, 15)
        XCTAssertEqual(records.filter { $0.issues.contains(.invalidMetadata) }.count, 1)
        let scanner = KiroUsageScanner(environment: FakeEnvironment(), homeDirectory: fixture.home)
        let scan = try await scanner.scan(now: now)
        XCTAssertEqual(scan?.daily.first?.tokens, 15)
        XCTAssertEqual(scan?.invalidRows, 1)
        XCTAssertEqual(scan?.readFailureCount, 0)
    }

    func testV3DiscoveryFailureStillCollectsLegacyDatabase() async throws {
        let fixture = try KiroCompletenessFixture()
        try fixture.replaceConversation(legacyConversation())
        let profile = fixture.home.appendingPathComponent("v3-profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: profile.appendingPathComponent("sessions"))
        let scanner = KiroUsageScanner(environment: FakeEnvironment(["KIRO_HOME": profile.path]), homeDirectory: fixture.home)
        let scan = try await scanner.scan(now: now)
        XCTAssertEqual(scan?.daily.first?.tokens, 15)
        XCTAssertEqual(scan?.readFailureCount, 1)
        XCTAssertFalse(scan?.readWarnings.isEmpty == true)
    }

    private func legacyConversation(credits: [[String: Any]] = [["unit": "credit", "value": 1]]) -> [String: Any] {
        ["model_info": ["model_id": "fixture-model"], "history": [[
            "request_metadata": ["request_start_timestamp_ms": (now.timeIntervalSince1970 - 1) * 1_000,
                                 "token_usage": ["input_tokens": 10, "output_tokens": 5]],
            "user_turn_metadata": ["usage_info": credits]
        ]]]
    }

    private func quotaResponse() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"subscriptionInfo":{"subscriptionTitle":"Kiro Pro"},"usageBreakdownList":[{"resourceType":"CREDIT","currentUsageWithPrecision":10,"usageLimitWithPrecision":50}]}"#.utf8
        ))
    }

    private func provider(scanner: KiroUsageScanner, http: FakeHTTPClient) -> KiroProvider {
        KiroProvider(authStore: KiroAuthStore(sqlite: KiroCompletenessAuth()),
                     usageClient: KiroUsageClient(http: http), usageScanner: scanner, now: { [now] in now })
    }

    private func store(_ runtime: KiroProvider) -> (WidgetDataStore, UserDefaults, String) {
        let suite = "KiroUsageCompletenessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let now = now
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        return (WidgetDataStore(registry: .from([runtime]), providers: [runtime], cache: cache,
                                defaults: defaults, now: { now }), defaults, suite)
    }

    private func value(_ lines: [MetricLine], label: String = "Today", kind: MetricKind) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values.first { $0.kind == kind }?.number
    }
}

@MainActor
private final class KiroCompletenessFixture {
    let home: URL
    let database: URL
    private var handle: OpaquePointer?
    var sessions: URL { home.appendingPathComponent(".kiro/sessions") }

    init() throws {
        home = try UsageRecordFixture.temporaryDirectory()
        database = home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE conversations_v2(conversation_id TEXT,value TEXT)")
    }

    func replaceConversation(_ object: [String: Any]?) throws {
        try execute("DELETE FROM conversations_v2")
        guard let object else { return }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        try execute("INSERT INTO conversations_v2 VALUES ('fixture', '\(json)')")
    }

    func addMalformedConversation() throws {
        try execute("INSERT INTO conversations_v2 VALUES ('broken', 'not-json')")
    }

    func writeV3(_ data: Data, profile: URL? = nil) throws {
        let root = profile.map { $0.appendingPathComponent("sessions") } ?? sessions
        let file = root.appendingPathComponent("workspace/session/messages.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.coderInvalidValue) }
    }

    isolated deinit {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: home)
    }
}

private struct KiroCompletenessAuth: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? {
        #"{"access_token":"fixture","expires_at":"2099-01-01T00:00:00Z","profile_arn":"fixture-profile"}"#
    }
    func execute(path: String, sql: String) throws {}
}
