import XCTest
@testable import OpenUsage

final class OpenRouterAnalyticsTests: XCTestCase {
    func testParsesReportedTotalsWithoutAddingCacheOrReasoningTokens() throws {
        let parsed = try OpenRouterAnalytics.parse(payload([
            "total_usage": "9.010831",
            "tokens_total": "161387945",
            "tokens_prompt": "156845926",
            "tokens_completion": "4542019",
            "cached_tokens": "140933166",
            "reasoning_tokens": "3088449"
        ]))

        XCTAssertEqual(parsed.values, [
            MetricValue(number: 9.010831, kind: .dollars),
            MetricValue(number: 161_387_945, kind: .count, label: "tokens")
        ])
        XCTAssertFalse(parsed.isPartial)
        XCTAssertTrue(parsed.values.allSatisfy { !$0.estimated })
    }

    func testKeepsExplicitZeroAndExactIntegerTokenBoundary() throws {
        for tokens: Any in [0, "0", "9007199254740991"] {
            let parsed = try OpenRouterAnalytics.parse(payload(["total_usage": 0, "tokens_total": tokens]))

            XCTAssertEqual(parsed.values.first?.number, 0)
            XCTAssertEqual(parsed.values.last?.number, Double(String(describing: tokens)))
            XCTAssertEqual(parsed.values.count, 2)
            XCTAssertFalse(parsed.isPartial)
        }
    }

    func testMissingTokensKeepsCostWithoutInventingZeroTokens() throws {
        let parsed = try OpenRouterAnalytics.parse(payload(["total_usage": 2.5]))

        XCTAssertEqual(parsed.values, [MetricValue(number: 2.5, kind: .dollars)])
        XCTAssertTrue(parsed.isPartial)
    }

    func testInvalidTokensKeepValidCostOnly() throws {
        let invalid: [Any] = [
            true, false, -1, 1.5, Double.nan, Double.infinity, NSNull(),
            "-1", "1.0000000000000001", "9007199254740992", "1e300", "NaN"
        ]
        for tokens in invalid {
            let parsed = try OpenRouterAnalytics.parse(payload(["total_usage": 2.5, "tokens_total": tokens]))

            XCTAssertEqual(parsed.values, [MetricValue(number: 2.5, kind: .dollars)], "\(tokens)")
            XCTAssertTrue(parsed.isPartial, "\(tokens)")
        }
    }

    func testMissingOrInvalidCostKeepsTokensOnly() throws {
        let invalid: [Any] = [true, false, -0.01, Double.nan, Double.infinity, NSNull(), "NaN", "-1"]
        let rows: [[String: Any]] = [["tokens_total": "42"]] + invalid.map { ["tokens_total": "42", "total_usage": $0] }
        for row in rows {
            let parsed = try OpenRouterAnalytics.parse(payload(row))

            XCTAssertEqual(parsed.values, [MetricValue(number: 42, kind: .count, label: "tokens")])
            XCTAssertTrue(parsed.isPartial)
        }
    }

    func testRejectsRowsWithNeitherUsableMetric() {
        for row: [String: Any] in [[:], ["total_usage": NSNull(), "tokens_total": NSNull()],
                                   ["total_usage": -1, "tokens_total": 1.5]] {
            XCTAssertThrowsError(try OpenRouterAnalytics.parse(payload(row))) { error in
                XCTAssertEqual(error as? OpenRouterUsageError, .invalidResponse)
            }
        }
    }

    func testRejectsIncompleteOrAmbiguousAggregateResponses() {
        let row: [String: Any] = ["total_usage": 2.5, "tokens_total": "42"]
        let invalid: [[String: Any]] = [
            ["data": [row]],
            ["data": [row], "metadata": ["row_count": 1]],
            ["data": [row], "metadata": ["row_count": 1, "truncated": true]],
            ["data": [row], "metadata": ["row_count": 1, "truncated": 0]],
            ["data": [row], "metadata": ["row_count": true, "truncated": false]],
            ["data": [row], "metadata": ["row_count": 2, "truncated": false]],
            ["data": [], "metadata": ["row_count": 0, "truncated": false]],
            ["data": [row, row], "metadata": ["row_count": 2, "truncated": false]],
            ["data": [row, row], "metadata": ["row_count": 1, "truncated": false]],
            ["data": row, "metadata": ["row_count": 1, "truncated": false]]
        ]
        for data in invalid {
            XCTAssertThrowsError(try OpenRouterAnalytics.parse(data)) { error in
                XCTAssertEqual(error as? OpenRouterUsageError, .invalidResponse)
            }
        }
    }

    private func payload(_ row: [String: Any]) -> [String: Any] {
        ["data": [row], "metadata": ["row_count": 1, "truncated": false]]
    }
}

final class OpenRouterAnalyticsPeriodTests: XCTestCase {
    func testUsesLocalPeriodBoundariesAndExistingLast30Window() {
        let calendar = calendar(timeZone: "Asia/Seoul")
        let now = date("2026-10-31T12:34:56Z")
        let expected: [(OpenRouterAnalyticsPeriod, String, String)] = [
            (.today, "2026-10-30T15:00:00Z", "2026-10-31T12:34:56Z"),
            (.yesterday, "2026-10-29T15:00:00Z", "2026-10-30T15:00:00Z"),
            (.last30, "2026-09-30T15:00:00Z", "2026-10-31T12:34:56Z"),
            (.week, "2026-10-25T15:00:00Z", "2026-10-31T12:34:56Z"),
            (.month, "2026-09-30T15:00:00Z", "2026-10-31T12:34:56Z")
        ]
        for (period, start, end) in expected {
            XCTAssertEqual(period.interval(now: now, calendar: calendar),
                           DateInterval(start: date(start), end: date(end)), period.rawValue)
        }
    }

    func testYesterdayFollowsDSTInsteadOfFixedSeconds() {
        let calendar = calendar(timeZone: "America/New_York")
        let cases: [(String, String, String, TimeInterval)] = [
            ("2026-03-09T12:00:00Z", "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23 * 3600),
            ("2026-11-02T12:00:00Z", "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25 * 3600)
        ]
        for (now, start, end, duration) in cases {
            let interval = OpenRouterAnalyticsPeriod.yesterday.interval(now: date(now), calendar: calendar)
            XCTAssertEqual(interval.start, date(start))
            XCTAssertEqual(interval.end, date(end))
            XCTAssertEqual(interval.duration, duration)
        }
    }

    func testLocalDaySupportsQuarterHourTimeZoneOffset() {
        let interval = OpenRouterAnalyticsPeriod.today.interval(
            now: date("2026-10-31T12:00:00Z"), calendar: calendar(timeZone: "Asia/Kathmandu")
        )

        XCTAssertEqual(interval.start, date("2026-10-30T18:15:00Z"))
        XCTAssertEqual(interval.end, date("2026-10-31T12:00:00Z"))
    }

    func testWeekHonorsCalendarFirstWeekday() {
        var calendar = calendar(timeZone: "Asia/Seoul")
        calendar.firstWeekday = 1

        let interval = OpenRouterAnalyticsPeriod.week.interval(now: date("2026-10-28T03:00:00Z"), calendar: calendar)

        XCTAssertEqual(interval.start, date("2026-10-24T15:00:00Z"))
    }

    private func calendar(timeZone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ value: String) -> Date { OpenUsageISO8601.date(from: value)! }
}

final class OpenRouterAnalyticsClientTests: XCTestCase {
    func testRequestsExactIntervalTotalsWithoutUTCBuckets() async throws {
        let responseBody = Data(#"{"data":{"data":[{"total_usage":0,"tokens_total":"0"}]}}"#.utf8)
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: responseBody)
        }
        let start = OpenUsageISO8601.date(from: "2026-10-30T15:00:00Z")!
        let end = OpenUsageISO8601.date(from: "2026-10-31T12:34:56Z")!

        let response = try await OpenRouterUsageClient(http: http).fetchAnalytics(apiKey: "test-key", start: start, end: end)

        XCTAssertEqual(response.body, responseBody)
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, OpenRouterUsageClient.analyticsURL)
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-key")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["metrics"] as? [String], ["total_usage", "tokens_total"])
        XCTAssertEqual(body["limit"] as? Int, 10)
        XCTAssertNil(body["granularity"])
        XCTAssertNil(body["dimensions"])
        let range = try XCTUnwrap(body["time_range"] as? [String: String])
        XCTAssertEqual(range["start"].flatMap(OpenUsageISO8601.date), start)
        XCTAssertEqual(range["end"].flatMap(OpenUsageISO8601.date), end)
    }

    func testPropagatesCancellationFromAnalyticsRequest() async {
        let http = RoutingHTTPClient { _ in throw CancellationError() }

        do {
            _ = try await OpenRouterUsageClient(http: http).fetchAnalytics(
                apiKey: "test-key", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1)
            )
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
