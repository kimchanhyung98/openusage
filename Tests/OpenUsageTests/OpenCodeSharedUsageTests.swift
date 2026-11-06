import XCTest
@testable import OpenUsage

@MainActor
final class OpenCodeSharedUsageTests: XCTestCase {
    private let now = OpenUsageISO8601.date(from: "2026-07-12T12:00:00Z")!

    func testReportedSharedCostReachesSpendWithoutChangingGoMeters() async throws {
        let provider = makeProvider(records: [record(cost: 2)], native: true)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 300)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 3)
        guard case let .progress(_, used, _, _, _, _, _)? = snapshot.line(label: "Session") else {
            return XCTFail("expected native Go meter")
        }
        XCTAssertEqual(used, 1)
    }

    func testEstimatedSharedCostKeepsTokensAndMakesTotalCostIncomplete() async {
        for origin in [UsageRecord.CostOrigin.estimated, .creditEquivalent] {
            let provider = makeProvider(records: [record(cost: 9, origin: origin)], native: true)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 300)
            XCTAssertNil(snapshot.usageHistory?.series.daily.first?.costUSD)
            XCTAssertNotNil(snapshot.line(label: "Usage Trend"))
        }
    }

    func testReportedZeroWithOnlySharedUsageDoesNotCreateGoMeters() async throws {
        let provider = makeProvider(records: [record(cost: 0)], native: false)
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0)
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.line(label: "Session"))
        guard case let .values(_, values, _, _, _, _)? = snapshot.line(label: "Today") else {
            return XCTFail("expected reported zero spend")
        }
        XCTAssertFalse(values.contains(where: \.estimated))
    }

    private func record(cost: Double, origin: UsageRecord.CostOrigin = .reported) -> UsageRecord {
        UsageRecord(
            sourceID: "pi", formatID: "pi-session", sessionID: "shared-session", id: "shared-request",
            kind: "message", timestamp: now.addingTimeInterval(-1800), providerID: "opencode-go",
            model: "glm-5.2", totalTokens: 200, recordedCostUSD: cost, costOrigin: origin
        )
    }

    private func makeProvider(records: [UsageRecord], native: Bool) -> OpenCodeProvider {
        let now = self.now
        let timestamp = Int(now.addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        let payload = "[[\(timestamp),1,100,\"glm-5.2\",\"opencode-go\"]]"
        return OpenCodeProvider(
            authStore: OpenCodeAuthStore(
                files: FakeFiles(), environment: FakeEnvironment(["OPENCODE_DATA_DIR": "/fixture"]),
                homeDirectory: { URL(fileURLWithPath: "/fixture-home") }
            ),
            usageScanner: OpenCodeUsageScanner(
                sqlite: SharedOpenCodeSQLite(payload: payload),
                databasePaths: { native ? ["/fixture/opencode.db"] : [] }
            ),
            sharedUsage: .init(collectors: [SharedOpenCodeRecords(records: records)]),
            now: { now }
        )
    }
}

private struct SharedOpenCodeRecords: UsageCollecting {
    let records: [UsageRecord]
    func collect(since: Date) async -> UsageCollection? { UsageCollection(records: records) }
}

private struct SharedOpenCodeSQLite: SQLiteAccessing {
    let payload: String
    func queryValue(path: String, sql: String) throws -> String? {
        if sql.contains("json_group_array") { return payload }
        return nil
    }
    func execute(path: String, sql: String) throws {}
}

