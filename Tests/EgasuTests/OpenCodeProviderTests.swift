import XCTest
@testable import Egasu

@MainActor
final class OpenCodeProviderTests: XCTestCase {
    private func d(_ iso: String) -> Date { EgasuISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),{\"total\":\(tokens)},\"\(model)\",\"\(provider)\"]"
    }
    private let authJSON = #"{"opencode-go":{"type":"api","key":"sk-test"}}"#

    private func authStore(files: TextFileAccessing) -> OpenCodeAuthStore {
        OpenCodeAuthStore(
            files: files,
            environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/oc"]),
            homeDirectory: { URL(fileURLWithPath: "/nonexistent") }
        )
    }

    func testHasLocalCredentialsViaGoAuthKey() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsViaLocalUsage() async {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            )
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testHasLocalCredentialsFalseWhenAbsent() async {
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": "[]"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            sharedUsage: .init(collectors: [])
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertFalse(has)
    }

    func testRefreshProducesMetersTilesAndTrend() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.plan, "Go")
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
        XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }

    func testExtremeFiniteCostsKeepMetersAndModelBreakdownEncodable() async throws {
        let now = d("2026-07-12T12:00:00.000Z")
        for costs in [["1e308"], ["1e308", "1e308"]] {
            let db = "[" + costs.enumerated().map { index, cost in
                row("2026-07-12T11:00:00.000Z", cost, 1, "model-\(index)", "opencode-go")
            }.joined(separator: ",") + "]"
            let provider = OpenCodeProvider(
                authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
                usageScanner: OpenCodeUsageScanner(
                    sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                    databasePaths: { ["/oc/opencode.db"] }
                ),
                sharedUsage: .init(collectors: []), now: { now }
            )
            let snapshot = await provider.refresh()
            XCTAssertNil(snapshot.errorCategory)
            for label in ["Session", "Weekly", "Monthly"] {
                guard case .progress(_, let used, _, _, _, _, _)? = snapshot.line(label: label) else {
                    return XCTFail("Missing progress: \(label)")
                }
                XCTAssertEqual(used, 1e308)
            }
            for label in ["Today", "Last 30 Days"] {
                guard case .values(_, _, _, _, _, let detail)? = snapshot.line(label: label) else {
                    return XCTFail("Missing spend: \(label)")
                }
                let breakdown = try XCTUnwrap(detail)
                XCTAssertEqual(breakdown.models.first?.costUSD, 1e308)
                XCTAssertEqual(breakdown.totalTokens, 1)
            }
            XCTAssertNil(snapshot.warning)
            XCTAssertNoThrow(try JSONEncoder().encode(snapshot.lines))
            let state = LocalUsageAPI.State(
                enabledOrderedIDs: ["opencode"], knownIDs: ["opencode"],
                snapshots: ["opencode": snapshot], limitDescriptors: ["opencode": provider.widgetDescriptors],
                generatedAt: now
            )
            let usage = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state)
            let usageRows = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(usage.body)) as? [[String: Any]])
            XCTAssertEqual(usageRows.count, 1, "Finite usage must not trigger the empty-response fallback")
            let limits = LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state)
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(limits.body)) as? [String: Any])
            XCTAssertNotNil((envelope["providers"] as? [String: Any])?["opencode"])
        }
    }

    func testRefreshNotLoggedInWhenNoKeyAndNoDatabase() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
    }

    func testRefreshKeepsValidUsageWithoutCardWarningWhenFiniteCostsOverflow() async throws {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + [
            row("2026-07-12T10:00:00.000Z", "1e308", 100, "gpt-5.5", "opencode"),
            row("2026-07-12T11:00:00.000Z", "1e308", 200, "gpt-5.5", "opencode")
        ].joined(separator: ",") + "]"
        let scanner = OpenCodeUsageScanner(sqlite: StubSQLite(data: ["/oc/opencode.db": db]), databasePaths: { ["/oc/opencode.db"] })
        let scanned = try await scanner.scan(now: now)
        let scan = try XCTUnwrap(scanned)
        XCTAssertEqual(scan.logScan.rejectedNumericRows, 1)
        let provider = OpenCodeProvider(authStore: authStore(files: FakeFiles()), usageScanner: scanner,
                                        sharedUsage: .init(collectors: []), now: { now })
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.warning)
        XCTAssertNil(snapshot.warningPresentation)
        XCTAssertEqual(snapshot.usageHistory, scan.logScan.usageHistory)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 100)
        XCTAssertNil(snapshot.errorCategory)
    }

    func testRefreshShowsZeroCapMetersWithGoKeyButNoDatabase() async {
        // Go 로그인 직후 첫 local message 이전 — key만으로 plan 확정, cap을 $0으로 표시
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Go")
        guard case .progress(_, let used, let limit, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected a Session meter")
        }
        XCTAssertEqual(used, 0)
        XCTAssertEqual(limit, OpenCodeUsageMapper.sessionCap)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertNotNil(snapshot.line(label: "Monthly"))
    }

    func testRefreshErrorsWhenAllDatabasesUnreadable() async {
        // 유효한 Go key + locked/corrupt DB → $0 meter 대신 read error 노출
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles(["/oc/auth.json": authJSON])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testRefreshSurfacesUnreadableAuthFileInsteadOfNotLoggedIn() async {
        // auth.json 존재하나 읽기 불가 + DB 없음 → logout이 아니라 storage 고장
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
    }

    func testUnreadableAuthWarnsWhenSharedHistoryBecomesEmptyAndClearsSavedTotals() async throws {
        let now = d("2026-07-12T12:00:00.000Z")
        let collector = OpenCodeAuthSharedRecords(records: [UsageRecord(
            sourceID: "pi", formatID: "fixture", kind: "message", timestamp: now.addingTimeInterval(-60),
            providerID: "opencode", model: "fixture", totalTokens: 200, recordedCostUSD: 2
        )])
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] }),
            sharedUsage: .init(collectors: [collector]), now: { now }
        )
        let suite = "OpenCodeProviderTests.auth-empty.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        let store = WidgetDataStore(registry: .from([provider]), providers: [provider], cache: cache,
                                    defaults: defaults, now: { now })
        await store.refreshAll(force: true)
        XCTAssertEqual(store.localSnapshots["opencode"]?.usageHistory?.series.daily.first?.totalTokens, 200)
        XCTAssertNil(store.localSnapshots["opencode"]?.warning)

        await collector.removeRecords()
        await store.refreshAll(force: true)

        let snapshot = try XCTUnwrap(store.localSnapshots["opencode"])
        let expected = OpenCodeUsageError.credentialsUnreadable(detail: "fixture")
        XCTAssertEqual(snapshot.usageHistory?.series.daily, [])
        XCTAssertEqual(cache.loadSnapshots(providerIDs: ["opencode"])["opencode"]?.usageHistory?.series.daily, [])
        XCTAssertEqual(snapshot.warning, expected.localizedDescription)
        XCTAssertEqual(snapshot.warningPresentation, [UserFacingErrors.presentation(expected)])
        XCTAssertEqual(L10n.withLanguage(.english) { store.headerNotice(for: "opencode") }, expected.localizedDescription)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(store.providerErrors["opencode"])
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testNativeReadFailureStillTakesPriorityOverUnreadableAuthAndEmptySharedHistory() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(failing: ["/oc/opencode.db"]), databasePaths: { ["/oc/opencode.db"] }
            ),
            sharedUsage: .init(collectors: [OpenCodeAuthSharedRecords(records: [])]), now: { now }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(snapshot.errorPresentation, UserFacingErrors.presentation(OpenCodeUsageError.databaseUnreadable))
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.line(label: "Session"))
    }

    func testHasLocalCredentialsTrueWhenAuthFileUnreadable() async {
        // 읽기 불가 auth.json도 OpenCode footprint — provider를 켜서 refresh()가 actionable error 표시
        let provider = OpenCodeProvider(
            authStore: authStore(files: UnreadableFiles(present: ["/oc/auth.json"])),
            usageScanner: OpenCodeUsageScanner(sqlite: StubSQLite(), databasePaths: { [] })
        )
        let has = await provider.hasLocalCredentials()
        XCTAssertTrue(has)
    }

    func testPartialDatabaseFailureIsVisibleInSnapshot() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/healthy.db": db], failing: ["/oc/locked.db"]),
                databasePaths: { ["/oc/healthy.db", "/oc/locked.db"] }
            ),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.warning, "Some local usage files could not be read. Usage history may be incomplete.")
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 500)
    }

    func testNativeSpendTilesAreMarkedEstimated() async {
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db]),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        guard case .values(_, let values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected a Today tile")
        }
        XCTAssertTrue(values.contains(where: \.estimated))
        let history = provider.widgetDescriptors.compactMap(\.historyResource).first
        XCTAssertEqual(history?.estimatedCost, true)
    }

    func testStaleGoHistoryDoesNotShowGoPlanOrMeters() async {
        // Zen-only 최근 usage + 오래된 opencode-go anchor + Go key 없음 — "Go" badge·cap meter 없이 Zen spend만 표시
        let now = d("2026-07-12T12:00:00.000Z")
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let provider = OpenCodeProvider(
            authStore: authStore(files: FakeFiles()),
            usageScanner: OpenCodeUsageScanner(
                sqlite: StubSQLite(data: ["/oc/opencode.db": db], anchor: "1700000000000"),
                databasePaths: { ["/oc/opencode.db"] }
            ),
            sharedUsage: .init(collectors: []), now: { now }
        )
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertNotNil(snapshot.line(label: "Today"))
    }
}

private final class StubSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchor: String?
    var failing: Set<String>
    init(data: [String: String] = [:], anchor: String? = nil, failing: Set<String> = []) {
        self.data = data
        self.anchor = anchor
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchor }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}

private actor OpenCodeAuthSharedRecords: UsageCollecting {
    private var records: [UsageRecord]

    init(records: [UsageRecord]) { self.records = records }

    func removeRecords() { records.removeAll() }

    func collect(since: Date) async -> UsageCollection? {
        UsageCollection(records: records, sources: [.init(sourceID: "pi", completedStores: 1)])
    }
}
