import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerCheckScheduleTests: XCTestCase {
    func testLaunchChecksOnceAndThenUsesQuarterHourBoundaries() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(10, 30), event: .deadline),
            .init(at: instant(10, 45), event: .deadline),
            .init(at: instant(11), event: .deadline)
        ])

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(10, 30), instant(10, 45), instant(11)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(10, 45), instant(11), instant(11, 15)])
    }

    func testCheckDurationDoesNotMoveOrLoseTheNextBoundary() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(10, 30), event: .deadline),
            .init(at: instant(10, 50), event: .deadline)
        ])
        let completionTime = instant(10, 50)
        timeline.onCheck = { timeline in
            if timeline.checks.count == 2 { timeline.now = completionTime }
        }

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(10, 30), instant(10, 50)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(10, 45), instant(11)])
    }

    func testWakeAfterSeveralMissedIntervalsChecksOnceAndResumesAtNextBoundary() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(15, 42), event: .wake),
            .init(at: instant(15, 43), event: .wake),
            .init(at: instant(15, 45), event: .deadline)
        ])

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(15, 42), instant(15, 45)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(15, 45), instant(15, 45), instant(16)])
    }

    func testEarlyWakeAndDuplicateDeadlineWakeEventsDoNotRepeatChecks() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(10, 20), event: .wake),
            .init(at: instant(10, 30), event: .deadline),
            .init(at: instant(10, 30), event: .wake),
            .init(at: instant(10, 30), event: .deadline),
            .init(at: instant(10, 45), event: .deadline)
        ])

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(10, 30), instant(10, 45)])
        XCTAssertEqual(timeline.deadlines, [
            instant(10, 30), instant(10, 30), instant(10, 45), instant(10, 45), instant(10, 45), instant(11)
        ])
    }

    func testForwardClockChangeCatchesUpOnceWhenFollowedByWake() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(13, 20), event: .clockChanged),
            .init(at: instant(13, 20), event: .wake),
            .init(at: instant(13, 30), event: .deadline)
        ])

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(13, 20), instant(13, 30)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(13, 30), instant(13, 30), instant(13, 45)])
    }

    func testBackwardClockChangeRecalculatesDeadlineWithoutImmediateCheck() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(9, 23), event: .clockChanged),
            .init(at: instant(9, 30), event: .deadline)
        ])

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(9, 30)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(9, 30), instant(9, 45)])
    }

    func testTimeZoneChangeKeepsQuarterHourBoundaries() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(10, 20), event: .clockChanged, timeZone: TimeZone(secondsFromGMT: 19_800)),
            .init(at: instant(10, 30), event: .deadline)
        ])

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(10, 30)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(10, 30), instant(10, 45)])
    }

    func testKathmanduUsesQuarterHourBoundaries() async {
        let timeline = Timeline(instant(10, 17), steps: [
            .init(at: instant(10, 30), event: .deadline),
            .init(at: instant(10, 45), event: .deadline)
        ])
        timeline.calendar.timeZone = TimeZone(identifier: "Asia/Kathmandu")!

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17), instant(10, 30), instant(10, 45)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30), instant(10, 45), instant(11)])
    }

    func testNewYorkFallBackChecksBothOccurrencesOfTheRepeatedHour() async {
        let formatter = ISO8601DateFormatter()
        let start = formatter.date(from: "2026-11-01T05:57:00Z")!
        let repeatedHour = formatter.date(from: "2026-11-01T06:00:00Z")!
        let followingHour = formatter.date(from: "2026-11-01T06:15:00Z")!
        let nextDeadline = formatter.date(from: "2026-11-01T06:30:00Z")!
        let timeline = Timeline(start, steps: [
            .init(at: repeatedHour, event: .deadline),
            .init(at: followingHour, event: .deadline)
        ])
        timeline.calendar.timeZone = TimeZone(identifier: "America/New_York")!

        await timeline.run()

        XCTAssertEqual(timeline.checks, [start, repeatedHour, followingHour])
        XCTAssertEqual(timeline.deadlines, [repeatedHour, followingHour, nextDeadline])
    }

    func testEndedWaitStopsAfterTheLaunchCheck() async {
        let timeline = Timeline(instant(10, 17))

        await timeline.run()

        XCTAssertEqual(timeline.checks, [instant(10, 17)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30)])
    }

    func testCancellationBeforeRunDoesNotCheckOrWait() async {
        let timeline = Timeline(instant(10, 17))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await timeline.run()
        }

        await task.value

        XCTAssertTrue(timeline.checks.isEmpty)
        XCTAssertTrue(timeline.deadlines.isEmpty)
    }

    func testCancellationDuringCheckDoesNotStartAnotherWait() async {
        let timeline = Timeline(instant(10, 17))
        timeline.onCheck = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let task = Task { await timeline.run() }

        await task.value

        XCTAssertEqual(timeline.checks, [instant(10, 17)])
        XCTAssertTrue(timeline.deadlines.isEmpty)
    }

    func testCancellationWhileWaitingIgnoresALateDeadline() async {
        let waiting = expectation(description: "Scheduled check waiting")
        let timeline = Timeline(instant(10, 17))
        let gate = WaitGate()
        let task = Task {
            await CodexWeeklyTimerCheckSchedule.run(
                now: { timeline.now },
                calendar: { timeline.calendar },
                wait: { deadline in
                    timeline.deadlines.append(deadline)
                    waiting.fulfill()
                    return await gate.wait()
                },
                check: { timeline.checks.append(timeline.now) }
            )
        }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        timeline.now = instant(11)
        gate.finish(.deadline)

        await task.value

        XCTAssertEqual(timeline.checks, [instant(10, 17)])
        XCTAssertEqual(timeline.deadlines, [instant(10, 30)])
    }

    private func instant(_ hour: Int, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: hour, minute: minute))!
    }

    @MainActor
    private final class Timeline {
        struct Step {
            let at: Date
            let event: CodexWeeklyTimerCheckSchedule.Event
            var timeZone: TimeZone?
        }

        var now: Date
        var calendar: Calendar
        var checks: [Date] = []
        var deadlines: [Date] = []
        var onCheck: (@MainActor (Timeline) async -> Void)?
        private var steps: [Step]

        init(_ now: Date, steps: [Step] = []) {
            self.now = now
            self.steps = steps
            calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        }

        func run() async {
            await CodexWeeklyTimerCheckSchedule.run(
                now: { self.now },
                calendar: { self.calendar },
                wait: { deadline in
                    self.deadlines.append(deadline)
                    guard !self.steps.isEmpty else { return nil }
                    let step = self.steps.removeFirst()
                    self.now = step.at
                    if let timeZone = step.timeZone { self.calendar.timeZone = timeZone }
                    return step.event
                },
                check: {
                    self.checks.append(self.now)
                    await self.onCheck?(self)
                }
            )
        }
    }

    @MainActor
    private final class WaitGate {
        private var finished = false
        private var continuation: CheckedContinuation<CodexWeeklyTimerCheckSchedule.Event?, Never>?

        func wait() async -> CodexWeeklyTimerCheckSchedule.Event? {
            guard !finished else { return nil }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ event: CodexWeeklyTimerCheckSchedule.Event) {
            finished = true
            continuation?.resume(returning: event)
            continuation = nil
        }
    }
}
