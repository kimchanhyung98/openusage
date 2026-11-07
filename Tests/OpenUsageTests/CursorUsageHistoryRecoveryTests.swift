import XCTest
@testable import OpenUsage

@MainActor
final class CursorUsageHistoryRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let header = "Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens"

    func testAllRejectedExportPreservesLastGoodHistoryAndLogsDegradation() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        let initial = try XCTUnwrap(fixture.store.localSnapshots["cursor"]?.usageHistory)
        XCTAssertEqual(initial.series.daily.first?.totalTokens, 100)
        await fixture.http.setCSV(csv(tokens: [-1]))

        let logs = try await captureLogs {
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
        }

        let retained = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(retained.usageHistory, initial)
        XCTAssertEqual(retained.isDegraded, true)
        XCTAssertNotNil(retained.line(label: "Total usage"))
        XCTAssertNotNil(retained.line(label: "Today"))
        XCTAssertNil(fixture.store.providerErrors["cursor"])
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["cursor"])["cursor"]?.usageHistory, initial)
        XCTAssertTrue(logs.contains("operation=history_scan result=degraded category=decoding"), logs)
        XCTAssertTrue(logs.contains("usage CSV ignored 1 malformed row"), logs)
    }

    func testHeaderOnlyExportClearsLastGoodHistoryWithoutDegradation() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 100)
        await fixture.http.setCSV(csv(tokens: []))

        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(try XCTUnwrap(snapshot.usageHistory).series.daily, [])
        XCTAssertNil(snapshot.isDegraded)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["cursor"])["cursor"]?.usageHistory?.series.daily, [])
    }

    func testMixedExportUsesValidRowsAndReplacesPreviousHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 100)
        await fixture.http.setCSV(csv(tokens: [40, -1]))

        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 40)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
    }

    private func makeFixture() throws -> (
        store: WidgetDataStore, http: CursorRecoveryHTTP, cache: ProviderSnapshotCache, defaults: UserDefaults, suite: String
    ) {
        let instant = now
        let http = CursorRecoveryHTTP(csv: csv(tokens: [100]))
        let payload = Data(#"{"sub":"google-oauth2|history-fixture","exp":9999999999}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: CursorRecoverySQLite(accessToken: "a.\(payload).c"), keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http), now: { instant }, pricing: { TestPricing.bundled }
        )
        let suite = "OpenUsageTests.CursorUsageHistoryRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { instant })
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults, now: { instant }
        )
        return (store, http, cache, defaults, suite)
    }

    private func csv(tokens: [Int]) -> String {
        let date = ISO8601DateFormatter().string(from: now)
        return header + "\n" + tokens.map { "\(date),composer-1,0,\($0),0,0\n" }.joined()
    }

    private func captureLogs(_ operation: () async -> Void) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.CursorRecovery.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }
        await operation()
        return try String(contentsOf: directory.appendingPathComponent("OpenUsage.log"), encoding: .utf8)
    }
}

private actor CursorRecoveryHTTP: HTTPClient {
    private var csv: String

    init(csv: String) { self.csv = csv }

    func setCSV(_ csv: String) { self.csv = csv }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        let body: String
        if url.contains("export-usage-events-csv") {
            body = csv
        } else if url.contains("GetCurrentPeriodUsage") {
            body = #"{"enabled":true,"planUsage":{"limit":100,"remaining":75,"totalPercentUsed":25}}"#
        } else if url.contains("GetPlanInfo") {
            body = #"{"planInfo":{"planName":"pro"}}"#
        } else if url.contains("GetCreditGrantsBalance") {
            body = #"{"hasCreditGrants":false}"#
        } else if url.contains("api/auth/stripe") {
            body = #"{"customerBalance":0}"#
        } else {
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

private struct CursorRecoverySQLite: SQLiteAccessing {
    let accessToken: String

    func queryValue(path: String, sql: String) throws -> String? {
        sql.contains(CursorAuthStore.accessTokenKey) ? accessToken : nil
    }

    func execute(path: String, sql: String) throws {}
}
