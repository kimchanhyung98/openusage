import XCTest
@testable import OpenUsage

final class OpenCodeGoWindowsTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private func d(_ iso: String) -> Date { OpenUsageISO8601.date(from: iso)! }
    private func epochMs(_ iso: String) -> Double { d(iso).timeIntervalSince1970 * 1000 }

    func testSessionRolling5Hours() {
        let now = d("2026-07-12T12:00:00.000Z")
        let costs: [(ms: Double, cost: Double)] = [
            (ms: epochMs("2026-07-12T11:00:00.000Z"), cost: 2.0),  // 1h 전, window 내
            (ms: epochMs("2026-07-12T08:30:00.000Z"), cost: 1.5),  // 3.5h 전, window 내 최고령
            (ms: epochMs("2026-07-12T06:00:00.000Z"), cost: 5.0)   // 6h 전, 5h window 밖
        ]
        let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: nil, now: now)
        XCTAssertEqual(windows.sessionSpend, 3.5, accuracy: 0.0001)
        // reset은 window 내 최고령 row + 5h (08:30 → 13:30)
        XCTAssertEqual(windows.sessionResetsAt, d("2026-07-12T13:30:00.000Z"))
    }

    func testSessionResetIsFiveHoursAheadWhenIdle() {
        let now = d("2026-07-12T12:00:00.000Z")
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: now)
        XCTAssertEqual(windows.sessionSpend, 0, accuracy: 0.0001)
        XCTAssertEqual(windows.sessionResetsAt, d("2026-07-12T17:00:00.000Z"))
    }

    func testWeeklyUTCMondayBoundary() {
        let now = d("2026-07-12T12:00:00.000Z") // 일요일
        let costs: [(ms: Double, cost: Double)] = [
            (ms: epochMs("2026-07-06T00:00:00.000Z"), cost: 4.0),  // 월요일 00:00, 주 시작 시점
            (ms: epochMs("2026-07-05T23:59:59.000Z"), cost: 9.0),  // 주 시작 직전, 제외
            (ms: epochMs("2026-07-12T11:00:00.000Z"), cost: 1.0)   // 주 내
        ]
        let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: nil, now: now)
        XCTAssertEqual(windows.weeklySpend, 5.0, accuracy: 0.0001)
        XCTAssertEqual(windows.weeklyResetsAt, d("2026-07-13T00:00:00.000Z"))
        XCTAssertEqual(utc.component(.weekday, from: windows.weeklyResetsAt!), 2) // 월요일
    }

    func testMonthlyAnchoredToEarliestDayOfMonth() {
        let now = d("2026-07-12T12:00:00.000Z")
        let anchor = epochMs("2026-03-05T09:30:00.000Z") // 5일 09:30
        let costs: [(ms: Double, cost: Double)] = [
            (ms: epochMs("2026-07-05T09:30:00.000Z"), cost: 10.0), // cycle 시작 시점, 포함
            (ms: epochMs("2026-07-05T09:29:59.000Z"), cost: 7.0),  // 1초 전, 제외
            (ms: epochMs("2026-07-11T00:00:00.000Z"), cost: 5.0)   // cycle 내
        ]
        let windows = OpenCodeGoWindowMath.compute(costs: costs, anchorMs: anchor, now: now)
        XCTAssertEqual(windows.monthlySpend, 15.0, accuracy: 0.0001)
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-08-05T09:30:00.000Z"))
        let start = d("2026-07-05T09:30:00.000Z")
        let end = d("2026-08-05T09:30:00.000Z")
        XCTAssertEqual(windows.monthlyPeriodMs, Int((end.timeIntervalSince1970 - start.timeIntervalSince1970) * 1000))
    }

    func testMonthlyAnchorLaterInMonthUsesPreviousCycle() {
        let now = d("2026-07-12T12:00:00.000Z")
        let anchor = epochMs("2026-01-20T00:00:00.000Z") // 20일 — 오늘(12일) 이후
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: anchor, now: now)
        // 7/20 시작은 미래이므로 현재 cycle은 6/20 → 7/20
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-07-20T00:00:00.000Z"))
    }

    func testMonthlyAnchorDayClampedForShortMonth() {
        let now = d("2026-06-15T12:00:00.000Z") // 6월은 30일까지
        let anchor = epochMs("2026-01-31T00:00:00.000Z") // 31일
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: anchor, now: now)
        // 6월은 31→30 clamp, 6/30 시작은 미래 → cycle은 5/31 → 6/30
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-06-30T00:00:00.000Z"))
    }

    func testMonthlyCalendarFallbackWithoutAnchor() {
        let now = d("2026-07-12T12:00:00.000Z")
        let windows = OpenCodeGoWindowMath.compute(costs: [], anchorMs: nil, now: now)
        XCTAssertEqual(windows.monthlyResetsAt, d("2026-08-01T00:00:00.000Z"))
    }
}
