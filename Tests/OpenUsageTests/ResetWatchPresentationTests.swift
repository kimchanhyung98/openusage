import XCTest
@testable import OpenUsage

@MainActor
final class ResetWatchPresentationTests: XCTestCase {
    func testForecastValueAndFillIgnoreUsedLeftMode() {
        var used = forecast(chance: 75)
        used.displayMode = .used
        var remaining = used
        remaining.displayMode = .remaining

        for data in [used, remaining] {
            XCTAssertEqual(data.displayedValue, 75)
            XCTAssertEqual(data.valueText, "75%")
            XCTAssertEqual(data.boundedHeadline, "75% chance")
            XCTAssertEqual(data.fraction, 0.75, accuracy: 0.000_001)
            XCTAssertEqual(data.menuBarValue, "75%")
        }
    }

    func testForecastSeverityUsesChanceBandsAndHundredPercentIsNotSpent() {
        XCTAssertEqual(forecast(chance: 39).meterState(), .level(.neutral))
        XCTAssertEqual(forecast(chance: 40).meterState(), .level(.normal))
        XCTAssertEqual(forecast(chance: 59).meterState(), .level(.normal))
        XCTAssertEqual(forecast(chance: 60).meterState(), .level(.warning))
        XCTAssertEqual(forecast(chance: 69).meterState(), .level(.warning))
        XCTAssertEqual(forecast(chance: 70).meterState(), .level(.critical))
        XCTAssertEqual(forecast(chance: 79).meterState(), .level(.critical))
        XCTAssertEqual(forecast(chance: 80).meterState(), .level(.critical))
        XCTAssertEqual(forecast(chance: 100).meterState(), .level(.critical))
        XCTAssertNotEqual(forecast(chance: 100).meterState(), .spent)
    }

    func testForecastHasNoQuotaToggleResetActionOrPace() {
        let now = Date(timeIntervalSince1970: 1_788_069_600)
        var data = forecast(chance: 90, deadline: now.addingTimeInterval(24 * 60 * 60))
        data.displayMode = .remaining
        data.resetsAt = now.addingTimeInterval(12 * 60 * 60)
        data.periodDurationMs = 24 * 60 * 60 * 1000
        data.alwaysShowPacing = true
        let state = data.meterState(now: now)

        XCTAssertFalse(data.hasMeterStyleToggle)
        XCTAssertNil(data.meterStyleTooltip)
        XCTAssertFalse(data.hasResetLabel(now: now))
        XCTAssertNil(data.resetTooltip(now: now))
        XCTAssertNil(data.paceTick(for: state, now: now))
        XCTAssertNil(state.tooltip)
    }

    func testForecastExpiresAtItsSemanticDeadline() {
        let deadline = Date(timeIntervalSince1970: 1_788_156_000)
        let data = forecast(chance: 75, deadline: deadline)

        XCTAssertTrue(data.presented(at: deadline.addingTimeInterval(-1)).hasData)

        let expired = data.presented(at: deadline)
        XCTAssertFalse(expired.hasData)
        XCTAssertEqual(expired.headline, WidgetData.noDataHeadline)
        XCTAssertEqual(expired.boundedTrailingText(now: deadline), WidgetData.noDataSubtitle)
        XCTAssertEqual(expired.meterState(now: deadline), .noData)
    }

    func testDeadlineFormatFollowsLocaleInTwentyFourHourMode() {
        let deadline = localDate(year: 2026, month: 8, day: 31, hour: 16)

        XCTAssertEqual(
            Formatters.resetWatchDeadlineLabel(
                at: deadline,
                locale: Locale(identifier: "en_US"),
                timeFormat: .twentyFourHour
            ),
            "By Aug 31, 16:00"
        )
        XCTAssertEqual(
            Formatters.resetWatchDeadlineLabel(
                at: deadline,
                locale: Locale(identifier: "en_GB"),
                timeFormat: .twentyFourHour
            ),
            "By 31 Aug, 16:00"
        )
        XCTAssertEqual(
            Formatters.resetWatchDeadlineLabel(
                at: deadline,
                locale: Locale(identifier: "ko_KR"),
                timeFormat: .twentyFourHour
            ),
            "By 8월 31일, 16:00"
        )
    }

    func testDeadlineFormatFollowsLocaleInTwelveHourMode() {
        let deadline = localDate(year: 2026, month: 8, day: 31, hour: 16)

        XCTAssertEqual(
            normalizedSpaces(Formatters.resetWatchDeadlineLabel(
                at: deadline,
                locale: Locale(identifier: "en_US"),
                timeFormat: .twelveHour
            )),
            "By Aug 31, 4:00 PM"
        )
        XCTAssertEqual(
            normalizedSpaces(Formatters.resetWatchDeadlineLabel(
                at: deadline,
                locale: Locale(identifier: "en_GB"),
                timeFormat: .twelveHour
            )),
            "By 31 Aug, 4:00 pm"
        )
        XCTAssertEqual(
            Formatters.resetWatchDeadlineLabel(
                at: deadline,
                locale: Locale(identifier: "ko_KR"),
                timeFormat: .twelveHour
            ),
            "By 8월 31일, 오후 4:00"
        )
    }

    func testPinnedForecastBuildsTextAndBarMenuContent() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.forecast(
            id: "codex.resetWatch",
            provider: provider,
            title: "Reset Watch"
        )
        var data = forecast(chance: 75, deadline: .distantFuture)
        data.displayMode = .remaining

        let content = MenuBarContentBuilder.build(
            groups: [ProviderMetrics(provider: provider, metrics: [descriptor])],
            data: { _ in data }
        )

        let metric = try XCTUnwrap(content.groups.first?.metrics.first)
        XCTAssertEqual(metric.id, "codex.resetWatch")
        XCTAssertEqual(metric.label, "Reset Watch")
        XCTAssertEqual(metric.value, "75%")
        XCTAssertEqual(metric.fraction, 0.75, accuracy: 0.000_001)
        XCTAssertTrue(metric.isBounded)
        XCTAssertTrue(metric.hasData)
        XCTAssertEqual(content.bars, [metric])
    }

    func testPinnedForecastPublishesDeadlineAndDisappearsAtThatInstant() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.forecast(
            id: "codex.resetWatch",
            provider: provider,
            title: "Reset Watch"
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = now.addingTimeInterval(60)
        let data = forecast(chance: 75, deadline: deadline)
        let groups = [ProviderMetrics(provider: provider, metrics: [descriptor])]

        let active = MenuBarContentBuilder.build(groups: groups, data: { _ in data }, now: now)
        XCTAssertEqual(active.nextInvalidation, deadline)
        XCTAssertFalse(active.isEmpty)

        let expired = MenuBarContentBuilder.build(groups: groups, data: { _ in data }, now: deadline)
        XCTAssertNil(expired.nextInvalidation)
        XCTAssertTrue(expired.isEmpty)
    }

    func testWidgetRowTimelineInsertsExactForecastDeadlineBetweenPeriodicTicks() {
        let start = Date(timeIntervalSince1970: 1_000)
        let deadline = start.addingTimeInterval(15)
        let schedule = WidgetRowTimelineSchedule(deadline: deadline, interval: 30)

        let entries = Array(schedule.entries(from: start, mode: .normal).prefix(4))

        XCTAssertEqual(entries, [start, deadline])
        XCTAssertEqual(Array(schedule.entries(from: deadline.addingTimeInterval(1), mode: .normal)),
                       [deadline.addingTimeInterval(1)])
        let periodic = WidgetRowTimelineSchedule(deadline: nil, interval: 30)
        XCTAssertEqual(Array(periodic.entries(from: start, mode: .normal).prefix(3)),
                       [start, start.addingTimeInterval(30), start.addingTimeInterval(60)])
    }

    private func forecast(chance: Double, deadline: Date = .distantFuture) -> WidgetData {
        var data = WidgetData(
            title: "Reset Watch",
            icon: .providerMark("codex"),
            kind: .percent,
            used: chance,
            limit: 100
        )
        data.isForecast = true
        data.forecastDeadline = deadline
        return data
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func normalizedSpaces(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
