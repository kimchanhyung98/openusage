import XCTest
@testable import OpenUsage

final class OpenCodeUsageScannerTests: XCTestCase {
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Int { Int(d(iso).timeIntervalSince1970 * 1000) }
    private func row(_ iso: String, _ cost: String, _ tokens: Int, _ model: String, _ provider: String) -> String {
        "[\(epochMs(iso)),\(cost),\(tokens),\"\(model)\",\"\(provider)\"]"
    }
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00.000Z")!

    private var db1: String {
        "[" + [
            row("2026-07-12T11:00:00.000Z", "2.0", 1000, "glm-5.2", "opencode-go"),  // 오늘·go·session 내
            row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode"),      // 오늘·zen
            row("2026-07-11T10:00:00.000Z", "3.0", 2000, "kimi-k2.6", "opencode-go"),// 어제·go
            row("2026-07-12T11:00:00.000Z", "null", 100, "x", "opencode-go"),        // 비용 null → 제외
            "\"garbage\""                                                             // 배열 아님 → 제외
        ].joined(separator: ",") + "]"
    }
    private var db2: String {
        "[" + row("2026-07-12T09:00:00.000Z", "4.0", 800, "deepseek-v4-pro", "opencode-go") + "]"
    }

    private func standardScanner() -> OpenCodeUsageScanner {
        let sqlite = FakeSQLite(data: [
            "/oc/opencode.db": db1,
            "/oc/opencode-next.db": db2
        ])
        return OpenCodeUsageScanner(sqlite: sqlite, databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] })
    }

    func testCombinedHostedSeriesUnionsDatabasesAndSkipsGarbage() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        let totalCost = scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +)
        let totalTokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        // opencode-go 2+3+4 + Zen 1 = 10 — null cost·"garbage" row 제외
        XCTAssertEqual(totalCost, 10.0, accuracy: 0.0001)
        XCTAssertEqual(totalTokens, 4300) // 계산: 1000 + 500 + 2000 + 800
    }

    func testSessionSumsOnlyGoAcrossDatabases() async throws {
        guard let scan = try await standardScanner().scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertNotNil(scan.goWindows)
        // session window(최근 5h)에 go row 2건(2.0, 4.0) 포함 — 10:00 Zen row는 Go cap에서 제외
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 6.0, accuracy: 0.0001)
    }

    func testZenOnlyUsageHasNoGoWindows() async throws {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertNil(scan.goWindows) // Go footprint 없음 → 빈 cap meter 미생성
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 1.0, accuracy: 0.0001)
    }

    func testMissingDatabaseReturnsNil() async throws {
        let scanner = OpenCodeUsageScanner(sqlite: FakeSQLite(), databasePaths: { [] })
        let scan = try await scanner.scan(now: now)
        XCTAssertNil(scan)
    }

    func testEmptyDatabaseYieldsEmptyScanNotNil() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertTrue(scan.logScan.series.daily.isEmpty)
        XCTAssertNil(scan.goWindows)
    }

    func testFailingDatabaseIsSkippedNotFatal() async throws {
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode-next.db": db2], failing: ["/oc/opencode.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        XCTAssertEqual(scan.logScan.series.daily.compactMap(\.costUSD).reduce(0, +), 4.0, accuracy: 0.0001)
    }

    func testAllDatabasesFailingThrowsInsteadOfEmptyScan() async {
        // 전 DB locked/corrupt — 빈 "success"는 $0 meter를 사실처럼 렌더 (silent-empty-scan 회귀 방지)
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(failing: ["/oc/opencode.db", "/oc/opencode-next.db"]),
            databasePaths: { ["/oc/opencode.db", "/oc/opencode-next.db"] }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testUnreadableDataDirectoryThrowsInsteadOfNil() async {
        // data dir enumerate 불가 → "미사용"이 아니라 접근 고장
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(),
            databasePaths: { throw CocoaError(.fileReadNoPermission) }
        )
        do {
            _ = try await scanner.scan(now: now)
            XCTFail("expected databaseUnreadable")
        } catch {
            XCTAssertEqual(error as? OpenCodeUsageError, .databaseUnreadable)
        }
    }

    func testHasHostedUsageProbe() {
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let withUsage = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertTrue(withUsage.hasHostedUsage())

        let empty = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": "[]"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        XCTAssertFalse(empty.hasHostedUsage())
    }

    func testAbsurdTokenCountIsClampedNotCrashing() async throws {
        // Int.max 초과 token count는 1e15로 clamp — Int(Double) 변환 trap 방지
        let db = "[[\(epochMs("2026-07-12T10:00:00.000Z")),1.0,1e19,\"glm-5.2\",\"opencode-go\"]]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now) else { return XCTFail("expected a scan") }
        let tokens = scan.logScan.series.daily.reduce(0) { $0 + $1.totalTokens }
        XCTAssertEqual(tokens, 1_000_000_000_000_000)
    }

    func testStaleGoAnchorWithoutRecentSpendOrKeyHasNoGoWindows() async throws {
        // 오래된 Go anchor만 있고 최근 Go spend·auth key 없음 — lapsed/Zen-only 사용자에게 cap·"Go" badge 미표시
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db], anchors: ["/oc/opencode.db": "1700000000000"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now, hasGoKey: false) else { return XCTFail("expected a scan") }
        XCTAssertNil(scan.goWindows)
    }

    func testGoKeyShowsWindowsEvenWithoutRecentSpend() async throws {
        // Go 로그인 상태로 window 내 idle → anchor 기준 월로 $0 cap 표시
        let db = "[" + row("2026-07-12T10:00:00.000Z", "1.0", 500, "gpt-5.5", "opencode") + "]"
        let scanner = OpenCodeUsageScanner(
            sqlite: FakeSQLite(data: ["/oc/opencode.db": db], anchors: ["/oc/opencode.db": "1700000000000"]),
            databasePaths: { ["/oc/opencode.db"] }
        )
        guard let scan = try await scanner.scan(now: now, hasGoKey: true) else { return XCTFail("expected a scan") }
        XCTAssertNotNil(scan.goWindows)
        XCTAssertEqual(scan.goWindows?.sessionSpend ?? -1, 0, accuracy: 0.0001)
    }
}

/// DB path별 payload 반환, SQL shape으로 query 분류하는 stub
private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var data: [String: String]
    var anchors: [String: String]
    var failing: Set<String>

    init(data: [String: String] = [:], anchors: [String: String] = [:], failing: Set<String> = []) {
        self.data = data
        self.anchors = anchors
        self.failing = failing
    }

    func queryValue(path: String, sql: String) throws -> String? {
        if failing.contains(path) { throw SQLiteError.queryFailed("boom") }
        if sql.contains("json_group_array") { return data[path] }
        if sql.contains("MIN(time_created)") { return anchors[path] }
        if sql.contains("SELECT 1") {
            let payload = data[path]
            return (payload != nil && payload != "[]" && !(payload ?? "").isEmpty) ? "1" : nil
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
