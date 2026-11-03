import XCTest
@testable import OpenUsage

@MainActor
final class DevinUsageScannerTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
    private let rates = ModelRates(inputPerMillion: 2, outputPerMillion: 10,
                                   cacheWritePerMillion: 2.5, cacheReadPerMillion: 0.2)

    private var pricing: ModelPricing {
        ModelPricing(supplement: PricingSupplement(pricing: ["test-model": rates]),
                     primary: PricingCatalog(), secondary: PricingCatalog())
    }

    func testOfficialFileShapeAddsBucketsWithoutContextSize() throws {
        let data = try node(request: "one", context: 999_999)
        let parsed = try DevinUsageScanner.parseLog(data, sessionID: "session")
        let result = DevinUsageScanner.aggregate(parsed, now: now, pricing: pricing)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 185)
        XCTAssertEqual(try XCTUnwrap(result.series.daily.first?.costUSD), 0.00073, accuracy: 0.00000001)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testNodeUpdatesAndForkCopiesCountOneRequest() throws {
        let source = try node(request: "shared", output: 10) + node(request: "shared", output: 50)
        var parsed = try DevinUsageScanner.parseLog(source, sessionID: "original")
        parsed.records += try DevinUsageScanner.parseLog(node(request: "shared"), sessionID: "fork").records
        parsed.records += try DevinUsageScanner.parseLog(node(request: "new"), sessionID: "fork").records

        let result = DevinUsageScanner.aggregate(parsed, now: now, pricing: pricing)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 370)
        XCTAssertEqual(parsed.records.count, 3)
    }

    func testPartialRecordsAcrossNodesKeepLargestRequest() throws {
        for outputs in [[10, 50], [50, 10]] {
            let data = try node(request: "shared", id: 1, output: outputs[0]) + node(request: "shared", id: 2, output: outputs[1])
            let result = DevinUsageScanner.aggregate(
                try DevinUsageScanner.parseLog(data, sessionID: "session"), now: now, pricing: pricing
            )
            XCTAssertEqual(result.series.daily.first?.totalTokens, 185)
        }
    }

    func testMessageIDFallbackDeduplicatesCopiesWithoutCollapsingDistinctMessages() throws {
        var first = message(request: nil)
        first["message_id"] = "message-one"
        var second = first
        second["message_id"] = "message-two"
        let data = try line(first, id: 1) + line(first, id: 2) + line(second, id: 3)
        let result = DevinUsageScanner.aggregate(
            try DevinUsageScanner.parseLog(data, sessionID: "session"), now: now, pricing: pricing
        )
        XCTAssertEqual(result.series.daily.first?.totalTokens, 370)
    }

    func testUnknownModelKeepsTokensAndOmitsWholePeriodCost() throws {
        var parsed = try DevinUsageScanner.parseLog(node(request: "priced"), sessionID: "session")
        var unknown = message(request: "unknown", model: "not-in-price-catalog")
        var metadata = unknown["metadata"] as! [String: Any]
        metadata["created_at"] = OpenUsageISO8601.string(from: now.addingTimeInterval(-86_400))
        unknown["metadata"] = metadata
        parsed.records += try DevinUsageScanner.parseLog(line(unknown), sessionID: "session").records
        let result = DevinUsageScanner.aggregate(parsed, now: now, pricing: pricing)
        let lines = result.totalSpendLines(now: now)

        XCTAssertNotNil(value(lines, "Today", .dollars))
        XCTAssertNil(value(lines, "Yesterday", .dollars))
        XCTAssertNil(value(lines, "Last 30 Days", .dollars))
        XCTAssertEqual(value(lines, "Last 30 Days", .count), 370)
        XCTAssertEqual(result.warnings.count, 1)
    }

    func testInvalidNumbersAndCompletedBadJSONAreReportedButActiveTailIsDeferred() throws {
        var data = try node(request: "valid")
        for (index, bad) in [true, -1, 1.5, "9223372036854775808"].enumerated() {
            var item = message(request: "invalid-\(index)")
            var metadata = item["metadata"] as! [String: Any]
            var metrics = metadata["metrics"] as! [String: Any]
            metrics["input_tokens"] = bad
            metadata["metrics"] = metrics
            item["metadata"] = metadata
            data += try line(item, id: index + 2)
        }
        data += Data("invalid-json\n{\"kind\":\"node\"".utf8)
        let parsed = try DevinUsageScanner.parseLog(data, sessionID: "session")
        let result = DevinUsageScanner.aggregate(parsed, now: now, pricing: pricing)

        XCTAssertEqual(result.series.daily.first?.totalTokens, 185)
        XCTAssertEqual(result.invalidRows, 5)
    }

    func testDateWindowUsesLocalDayAndRejectsFutureRecords() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let midnight = calendar.startOfDay(for: now)
        let dates = [midnight.addingTimeInterval(-1), midnight, now.addingTimeInterval(1),
                     calendar.date(byAdding: .day, value: -31, to: midnight)!]
        let parsed = DevinUsageScanner.Parsed(records: dates.enumerated().map { index, date in
            .init(id: String(index), timestamp: date, model: "test-model", tokens: TokenBreakdown(input: 10))
        })
        let result = DevinUsageScanner.aggregate(parsed, now: now, pricing: pricing, calendar: calendar)

        XCTAssertEqual(result.series.daily.count, 2)
        XCTAssertEqual(result.series.daily.reduce(0) { $0 + $1.totalTokens }, 20)
    }

    func testSQLiteAndFolderStoreShareRequestIdentityAndRemainReadOnly() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "shared"), at: now)
        try fixture.writeLog(node(request: "shared") + node(request: "new", id: 2))
        let databaseBefore = try Data(contentsOf: fixture.database)
        let logBefore = try Data(contentsOf: fixture.log)

        let result = try await fixture.scanner().scan(now: now, pricing: pricing)

        XCTAssertEqual(result?.series.daily.first?.totalTokens, 370)
        XCTAssertEqual(try Data(contentsOf: fixture.database), databaseBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.log), logBefore)
    }

    func testMissingAndEmptyStoresDoNotInventZeroUsage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scanner = DevinUsageScanner(environment: FakeEnvironment(["DEVIN_SESSIONS_DIR": root.path]))
        let missing = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertNil(missing)
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        let empty = try await fixture.scanner().scan(now: now, pricing: pricing)
        XCTAssertEqual(empty?.totalSpendLines(now: now), [])
    }

    func testUnreadableDatabaseKeepsValidFileHistoryAndWarns() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.writeLog(node(request: "file"))
        try Data("invalid sqlite".utf8).write(to: fixture.database)

        let result = try await fixture.scanner().scan(now: now, pricing: pricing)

        XCTAssertEqual(result?.series.daily.first?.totalTokens, 185)
        XCTAssertEqual(result?.invalidRows, 1)
        XCTAssertFalse(result?.warnings.isEmpty ?? true)
    }

    func testUnreadableFileStoreKeepsValidDatabaseHistoryAndWarns() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "database"), at: now)
        try Data("not a directory".utf8).write(to: fixture.database.deletingLastPathComponent().appendingPathComponent("sessions"))

        let result = try await fixture.scanner().scan(now: now, pricing: pricing)

        XCTAssertEqual(result?.series.daily.first?.totalTokens, 185)
        XCTAssertEqual(result?.invalidRows, 1)
        XCTAssertFalse(result?.warnings.isEmpty ?? true)
    }

    func testConfiguredPathsFollowCLIStorageRoot() async {
        let home = URL(fileURLWithPath: "/fixture-home", isDirectory: true)
        let xdg = DevinUsageScanner(environment: FakeEnvironment(["XDG_DATA_HOME": "/fixture-data"]), homeDirectory: home)
        let override = DevinUsageScanner(environment: FakeEnvironment([
            "DEVIN_SESSIONS_DIR": "~/history", "XDG_DATA_HOME": "/ignored"
        ]), homeDirectory: home)
        let xdgPath = await xdg.directory.path
        let overridePath = await override.directory.path
        XCTAssertEqual(xdgPath, "/fixture-data/devin/cli")
        XCTAssertEqual(overridePath, "/fixture-home/history/cli")
    }

    func testShellHistoryPathIsResolvedWhenTheScanRunsOffMain() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "one"), at: now)
        let runner = DevinHistoryShellRunner(stdout: [
            "__OPENUSAGE_ENV_BEGIN__", "DEVIN_SESSIONS_DIR=\(fixture.root.path)", "__OPENUSAGE_ENV_END__"
        ].joined(separator: "\0"))
        let environment = ProcessEnvironmentReader(
            processEnvironment: [:], shellEnvironment: LoginShellEnvironment(runner: runner), launchSnapshot: { nil }
        )
        let scanner = DevinUsageScanner(environment: environment, homeDirectory: fixture.root)
        let result = try await scanner.scan(now: now, pricing: pricing)
        XCTAssertEqual(result?.series.daily.first?.totalTokens, 185)
    }

    func testNullCacheCountersKeepOrdinaryRequestTokens() throws {
        var item = message(request: "one")
        var metadata = item["metadata"] as! [String: Any]
        var metrics = metadata["metrics"] as! [String: Any]
        metrics["cache_read_tokens"] = NSNull()
        metrics["cache_creation_tokens"] = NSNull()
        metadata["metrics"] = metrics
        item["metadata"] = metadata
        let parsed = try DevinUsageScanner.parseLog(line(item), sessionID: "fixture")
        XCTAssertEqual(parsed.records.first?.tokens.totalTokens, 150)
        XCTAssertEqual(parsed.invalidRows, 0)
    }

    func testMalformedAssistantMetadataWarnsButAbsentUsageDoesNot() throws {
        let items: [[String: Any]] = [
            ["role": "assistant"], ["role": "assistant", "metadata": NSNull()],
            ["role": "assistant", "metadata": [:]],
            ["role": "assistant", "metadata": ["metrics": NSNull()]],
            ["role": "assistant", "metadata": "invalid"],
            ["role": "assistant", "metadata": ["metrics": "invalid"]]
        ]
        var data = try node(request: "valid")
        for (index, item) in items.enumerated() { data += try line(item, id: index + 2) }
        let parsed = try DevinUsageScanner.parseLog(data, sessionID: "fixture")
        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertEqual(parsed.invalidRows, 2)
    }

    func testSQLiteCorruptRowsDoNotDiscardValidHistory() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "valid"), at: now)
        try fixture.insert(["role": "assistant", "metadata": "invalid"], at: now)
        try fixture.insert(["role": "assistant", "metadata": ["metrics": "invalid"]], at: now)
        try fixture.insert(["role": "assistant", "metadata": ["metrics": NSNull()]], at: now)
        try fixture.insert(["role": "assistant"], at: now)
        try fixture.execute("INSERT INTO message_nodes VALUES('bad',2,0,'not-json');")
        let result = try await fixture.scanner().scan(now: now, pricing: pricing)
        XCTAssertEqual(result?.series.daily.first?.totalTokens, 185)
        XCTAssertEqual(result?.invalidRows, 3)
    }

    func testDamagedSessionsPreserveOtherFilesAndDatabaseRecords() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "database"), at: now)
        try fixture.writeLog(node(request: "file"))
        let metadata: [String?] = [nil, "not-json", #"{"v":2,"id":"old"}"#, #"{"v":1,"id":"directory-log"}"#]
        for (index, meta) in metadata.enumerated() {
            let session = fixture.log.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("bad-\(index)")
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            if let meta { try Data(meta.utf8).write(to: session.appendingPathComponent("meta.json")) }
            let log = session.appendingPathComponent("log.jsonl")
            if index == 3 {
                try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
            } else {
                try node(request: "bad-\(index)").write(to: log)
            }
        }
        let result = try await fixture.scanner().scan(now: now, pricing: pricing)
        XCTAssertEqual(result?.series.daily.first?.totalTokens, 370)
        XCTAssertEqual(result?.invalidRows, 4)
        XCTAssertFalse(result?.warnings.isEmpty ?? true)
    }

    func testProviderFeedsDashboardWithoutChangingQuotaRows() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "one"), at: now)
        let frozenNow = now
        let frozenPricing = pricing
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles([DevinAuthStore.credentialsPath: "windsurf_api_key = 'fixture'"]),
                                      sqlite: DevinHistoryAuthSQLite()),
            usageClient: DevinUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 200, headers: [:], body: Data(#"{"userStatus":{"planStatus":{"planInfo":{"planName":"Max"},"dailyQuotaRemainingPercent":80,"weeklyQuotaRemainingPercent":60,"overageBalanceMicros":"9000000"}}}"#.utf8)
            ))),
            usageScanner: fixture.scanner(), now: { frozenNow }, pricing: { frozenPricing }
        )
        let snapshot = await provider.refresh()
        let total = TotalSpendAggregator.total(for: .today, providers: [provider.provider], snapshots: ["devin": snapshot])

        XCTAssertEqual(snapshot.lines.count, 3)
        XCTAssertNil(snapshot.lines.first(where: { $0.label == "Today" }))
        XCTAssertEqual(total.slices.first?.tokenCount, 185)
        XCTAssertEqual(try XCTUnwrap(total.slices.first?.amountUSD), 0.00073, accuracy: 0.00000001)
        XCTAssertTrue(total.slices.first?.estimated == true)
    }

    func testLocalHistorySurvivesQuotaFailure() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try fixture.insert(message(request: "one"), at: now)
        let frozenNow = now
        let frozenPricing = pricing
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles([DevinAuthStore.credentialsPath: "windsurf_api_key = 'fixture'"]),
                                      sqlite: DevinHistoryAuthSQLite()),
            usageClient: DevinUsageClient(http: http), usageScanner: fixture.scanner(),
            now: { frozenNow }, pricing: { frozenPricing }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(snapshot.errorCategory, DevinUsageError.quotaUnavailable.errorCategory)
        XCTAssertEqual(value(snapshot.totalSpendLines ?? [], "Today", .count), 185)
    }

    func testUnreadableHistoryKeepsQuotaAndAddsLocalizedWarning() async throws {
        let fixture = try DevinHistoryFixture()
        defer { fixture.remove() }
        try Data("not-sqlite".utf8).write(to: fixture.database)
        let frozenNow = now
        let provider = DevinProvider(
            authStore: DevinAuthStore(files: FakeFiles([DevinAuthStore.credentialsPath: "windsurf_api_key = 'fixture'"]),
                                      sqlite: DevinHistoryAuthSQLite()),
            usageClient: DevinUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                statusCode: 200, headers: [:], body: Data(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80}}}"#.utf8)
            ))),
            usageScanner: fixture.scanner(), now: { frozenNow }, pricing: { .empty }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.isDegraded == true)
        XCTAssertEqual(snapshot.warningPresentation?.count, 1)
        XCTAssertNil(snapshot.totalSpendLines)
        XCTAssertFalse(snapshot.lines.isEmpty)
    }

    func testHistoryFailuresRetainCachedTotalsUntilAConfirmedEmptyScan() async throws {
        for corruptDatabase in [true, false] {
            let fixture = try DevinHistoryFixture()
            defer { fixture.remove() }
            try fixture.insert(message(request: "one"), at: now)
            let frozenNow = now
            let frozenPricing = pricing
            let provider = DevinProvider(
                authStore: DevinAuthStore(
                    files: FakeFiles([DevinAuthStore.credentialsPath: "windsurf_api_key = 'fixture'"]),
                    sqlite: DevinHistoryAuthSQLite()
                ),
                usageClient: DevinUsageClient(http: FakeHTTPClient(response: HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"userStatus":{"planStatus":{"dailyQuotaRemainingPercent":80}}}"#.utf8)
                ))),
                usageScanner: fixture.scanner(), now: { frozenNow }, pricing: { frozenPricing }
            )
            let suite = "DevinUsageScannerTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { frozenNow })
            let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache,
                                        defaults: defaults, now: { frozenNow })
            await store.refreshAll(force: true)
            let previous = try XCTUnwrap(store.localSnapshots["devin"]?.totalSpendLines)
            XCTAssertEqual(value(previous, "Today", .count), 185)

            if corruptDatabase {
                try Data("not-sqlite".utf8).write(to: fixture.database)
            } else {
                try FileManager.default.removeItem(at: fixture.database)
                try fixture.writeLog(node(request: "one"))
                try Data("not-json".utf8).write(to: fixture.log.deletingLastPathComponent().appendingPathComponent("meta.json"))
            }
            await store.refreshAll(force: true)
            let retained = store.localSnapshots["devin"]
            XCTAssertEqual(retained?.totalSpendLines, previous)
            XCTAssertNotNil(retained?.warning)
            XCTAssertNil(store.providerErrors["devin"])
            XCTAssertEqual(cache.loadSnapshots(providerIDs: ["devin"])["devin"]?.totalSpendLines, previous)

            let directory = fixture.database.deletingLastPathComponent()
            try FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try fixture.execute("CREATE TABLE message_nodes(session_id TEXT, node_id INTEGER, created_at INTEGER, chat_message TEXT);")
            await store.refreshAll(force: true)
            XCTAssertEqual(store.localSnapshots["devin"]?.totalSpendLines, [])
            XCTAssertNil(store.localSnapshots["devin"]?.warning)
        }
    }

    private func node(request: String, id: Int = 1, output: Int = 50, context: Int = 135) throws -> Data {
        try line(message(request: request, output: output, context: context), id: id)
    }

    private func message(request: String?, model: String = "test-model", output: Int = 50, context: Int = 135) -> [String: Any] {
        var metadata: [String: Any] = [
            "created_at": OpenUsageISO8601.string(from: now.addingTimeInterval(-1)), "generation_model": model,
            "metrics": ["input_tokens": 100, "output_tokens": output, "cache_read_tokens": 25,
                        "cache_creation_tokens": 10, "context_input_tokens": context, "total_time_ms": 20]
        ]
        metadata["request_id"] = request
        return ["role": "assistant", "metadata": metadata]
    }

    private func line(_ message: [String: Any], id: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "kind": "node", "at": Int(now.timeIntervalSince1970),
            "node": ["id": id, "message": message]
        ]) + Data([0x0A])
    }

    private func value(_ lines: [MetricLine], _ label: String, _ kind: MetricKind) -> Double? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values.first(where: { $0.kind == kind })?.number
    }
}

private struct DevinHistoryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var database: URL { root.appendingPathComponent("cli/sessions.db") }
    var log: URL { root.appendingPathComponent("cli/sessions/fixture/log.jsonl") }

    init() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("cli"), withIntermediateDirectories: true)
        try execute("CREATE TABLE message_nodes(session_id TEXT, node_id INTEGER, created_at INTEGER, chat_message TEXT);")
    }

    func scanner() -> DevinUsageScanner {
        DevinUsageScanner(environment: FakeEnvironment(["DEVIN_SESSIONS_DIR": root.path]))
    }

    func insert(_ message: [String: Any], at date: Date) throws {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: message), as: UTF8.self)
            .replacingOccurrences(of: "'", with: "''")
        try execute("INSERT INTO message_nodes VALUES('fixture',1,\(Int(date.timeIntervalSince1970)),'\(json)');")
    }

    func writeLog(_ data: Data) throws {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"v":1,"id":"fixture"}"#.utf8).write(to: log.deletingLastPathComponent().appendingPathComponent("meta.json"))
        try data.write(to: log)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func execute(_ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [database.path, sql]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DevinHistoryError.unreadable }
    }
}

private struct DevinHistoryShellRunner: ProcessRunning {
    let stdout: String

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}

private struct DevinHistoryAuthSQLite: SQLiteAccessing {
    func queryValue(path: String, sql: String) throws -> String? { nil }
    func execute(path: String, sql: String) throws {}
}
