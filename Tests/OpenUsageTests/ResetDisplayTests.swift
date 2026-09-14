import XCTest
@testable import OpenUsage

final class ResetDisplayTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAbsoluteLabelDayBuckets() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))! // 정오 고정, 날짜 경계 회피

        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(2 * 3600),
                                                    now: now, calendar: calendar)!.hasPrefix("Resets today at "))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!.addingTimeInterval(3600)
        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: tomorrow,
                                                    now: now, calendar: calendar)!.hasPrefix("Resets tomorrow at "))

        let later = calendar.date(byAdding: .day, value: 5, to: now)!
        let label = Formatters.resetAbsoluteLabel(at: later, now: now, calendar: calendar)!
        XCTAssertTrue(label.hasPrefix("Resets ") && label.contains(" at "))
        XCTAssertFalse(label.hasPrefix("Resets today"))
        XCTAssertFalse(label.hasPrefix("Resets tomorrow"))

        XCTAssertEqual(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(-1),
                                                     now: now, calendar: calendar), "Resets soon")
    }

    func testWidgetDataTrailingAndTooltipHonorMode() {
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"),
                              kind: .percent, used: 50, limit: 100)
        data.resetsAt = Date().addingTimeInterval(4 * 24 * 3600 + 17 * 3600)
        data.periodDurationMs = 7 * 24 * 60 * 60 * 1000
        XCTAssertTrue(data.hasResetLabel())

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.boundedTrailingText()?.hasPrefix("Resets in "), true)
        XCTAssertEqual(data.resetTooltip()?.hasPrefix("Resets "), true)

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.boundedTrailingText()?.hasPrefix("Resets "), true)
        XCTAssertEqual(data.resetTooltip()?.hasPrefix("Resets in "), true)
    }

    func testZeroUsageSessionSignalPreservesAntigravityAndKimiBehavior() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let period: TimeInterval = 5 * 3600
        for id in ["antigravity.geminiPro", "antigravity.claude", "kimi.session"] {
            var data = WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent, used: 0, limit: 100)
            data.sessionStartSignal = .zeroUsage
            data.periodDurationMs = Int(period * 1000)
            // window 절반 경과에도 usage 0이면 "Not started" (isFreshSessionWindow 기준)
            data.resetsAt = now.addingTimeInterval(period / 2)
            XCTAssertEqual(data.boundedTrailingText(now: now), "Not started", id)
            XCTAssertFalse(data.hasResetLabel(now: now), id)
            XCTAssertEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip, id)
            // "Not started" 상태에서는 pacing 강제에도 pace projection·tick 없음
            data.alwaysShowPacing = true
            let state = data.meterState(now: now)
            XCTAssertEqual(state, .level(.normal), id)
            XCTAssertNil(state.tooltip, id)
            XCTAssertNil(data.paceTick(for: state, now: now), id)
            data.resetsAt = now
            XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
            data.resetsAt = nil
            XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
        }
    }

    func testClaudeSessionStartUsesMissingResetDateInBothDisplayModes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(9_000)
        for mode in [WidgetDisplayMode.used, .remaining] {
            for resetMode in [ResetDisplayMode.relative, .absolute] {
                var data = WidgetData(title: "Session", icon: .providerMark("claude"),
                                      kind: .percent, used: 0, limit: 100, displayMode: mode,
                                      resetDisplayMode: resetMode, periodDurationMs: MetricPeriod.sessionMs)
                data.sessionStartSignal = .missingResetDate
                XCTAssertEqual(data.boundedTrailingText(now: now), "Not started")
                XCTAssertEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip)
                XCTAssertFalse(data.hasResetLabel(now: now))

                data.resetsAt = future
                XCTAssertFalse(data.isFreshSessionWindow(now: now))
                XCTAssertTrue(data.hasResetLabel(now: now))
                XCTAssertEqual(data.boundedTrailingText(now: now), resetMode == .relative
                    ? Formatters.resetRelativeLabel(until: future, now: now)
                    : Formatters.resetAbsoluteLabel(at: future, now: now))
                XCTAssertEqual(data.meterState(now: now), .level(.normal))
                XCTAssertNil(data.paceTick(for: data.meterState(now: now), now: now))

                data.resetsAt = now.addingTimeInterval(-1)
                XCTAssertFalse(data.isFreshSessionWindow(now: now))
                XCTAssertEqual(data.boundedTrailingText(now: now), "Resets soon")
            }
        }
    }

    func testMissingResetSignalRequiresZeroUsageAndRealBoundedData() {
        var data = WidgetData(title: "Session", icon: .providerMark("claude"), kind: .percent,
                              used: 1, limit: 100, sessionStartSignal: .missingResetDate)
        XCTAssertFalse(data.isFreshSessionWindow())
        data.used = 0
        data.hasData = false
        XCTAssertFalse(data.isFreshSessionWindow())
        XCTAssertEqual(data.boundedTrailingText(), WidgetData.noDataSubtitle)
        data.hasData = true
        data.limit = nil
        XCTAssertFalse(data.isFreshSessionWindow())
    }

    @MainActor
    func testSessionStartSignalsAreWiredOnExactlyTheShippingDescriptors() {
        let providers: [ProviderRuntime] = [
            ClaudeProvider(), CodexProvider(), CursorProvider(),
            AntigravityProvider(), CopilotProvider(), DevinProvider(),
            GrokProvider(), KimiProvider(), KiroProvider(), OpenCodeProvider(), OpenRouterProvider(), ZAIProvider()
        ]
        let descriptors = providers.flatMap(\.widgetDescriptors)
        let signals = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            descriptor.sample.sessionStartSignal.map { (descriptor.id, $0) }
        })
        XCTAssertEqual(signals, ["claude.session": .missingResetDate,
                                 "antigravity.geminiPro": .zeroUsage, "antigravity.claude": .zeroUsage,
                                 "kimi.session": .zeroUsage])

        let suffixed = descriptors.filter { $0.sample.traySuffix != nil }
        XCTAssertEqual(suffixed.map(\.id), ["codex.rateLimitResets"])
        XCTAssertEqual(suffixed.first?.sample.traySuffix, "resets")
    }

    func testAntigravityWeeklyRowsNeverReadNotStarted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let period: TimeInterval = 7 * 24 * 3600
        for id in ["antigravity.geminiWeekly", "antigravity.claudeWeekly"] {
            var data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: 0, limit: 100)
            data.periodDurationMs = Int(period * 1000)
            data.resetsAt = now.addingTimeInterval(period / 2)
            XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
            XCTAssertNotEqual(data.boundedTrailingText(now: now), "Not started", id)
            XCTAssertEqual(data.boundedTrailingText(now: now)?.hasPrefix("Resets"), true, id)
        }
    }

    func testExpiryTooltipSingleCreditFollowsTimeSetting() {
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 1, kind: .count, label: "available")]
        data.expiriesAt = [Date().addingTimeInterval(12 * 24 * 3600 + 18 * 3600)]

        XCTAssertEqual(data.unboundedDetail, "1 available")

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.expiryTooltip, "Reset expires in 12d 18h")

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.expiryTooltip?.hasPrefix("Reset expires "), true)
        XCTAssertEqual(data.expiryTooltip?.contains(" at "), true)
    }

    func testExpiryTooltipMultipleCreditsIsNumberedList() {
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]
        data.expiriesAt = [
            Date().addingTimeInterval(12 * 24 * 3600 + 18 * 3600),
            Date().addingTimeInterval(22 * 24 * 3600 + 12 * 3600)
        ]
        data.resetDisplayMode = .relative

        XCTAssertEqual(data.unboundedDetail, "2 available")
        XCTAssertEqual(data.expiryTooltip, "Resets expire in:\n1. 12d 18h\n2. 22d 12h")
    }

    func testExpirySeverityTracksSoonestExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]

        data.expiriesAt = [
            now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600),
            now.addingTimeInterval(WidgetData.expiryWarningWindow + 10 * 24 * 3600)
        ]
        XCTAssertEqual(data.expirySeverity(now: now), .critical)

        data.expiriesAt = [now.addingTimeInterval(WidgetData.expiryCriticalWindow + 3600)]
        XCTAssertEqual(data.expirySeverity(now: now), .warning)

        data.expiriesAt = [now.addingTimeInterval(WidgetData.expiryWarningWindow + 24 * 3600)]
        XCTAssertEqual(data.expirySeverity(now: now), .normal)

        data.expiriesAt = []
        XCTAssertNil(data.expirySeverity(now: now))
    }

    func testNoExpiryTooltipWhenNoExpiries() {
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 0, kind: .count, label: "available")]
        XCTAssertEqual(data.unboundedDetail, "0 available")
        XCTAssertNil(data.expiryTooltip)
    }

    func testResetsPopoverEntriesAreSoonestFirstAndNumbered() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(
            from: [
                // 정렬 검증용 역순 입력
                now.addingTimeInterval(12 * 24 * 3600 + 18 * 3600),
                now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600)
            ],
            now: now
        )

        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(entries[0].severity, .critical)
        XCTAssertEqual(entries[1].severity, .normal)
        XCTAssertEqual(entries[1].time.contains(" at "), true)
        XCTAssertEqual(entries[1].countdown, "12d 18h")
    }

    func testResetsPopoverPastDueEntryReadsSoonWithNoCountdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(-60)], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].time, "Expiring soon")
        XCTAssertNil(entries[0].countdown)
        XCTAssertEqual(entries[0].severity, .critical)
    }

    func testResetsPopoverImminentFutureCreditCollapsesToSoon() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(180)], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].time, "Expiring soon")
        XCTAssertNil(entries[0].countdown)
    }

    func testResetsPopoverEmptyWhenNoCredits() {
        XCTAssertTrue(RateLimitResetsDetail.entries(from: [], now: Date()).isEmpty)
    }

    func testCompactDurationAlwaysShowsHoursAtDayScale() {
        XCTAssertEqual(Formatters.compactDuration(4 * 24 * 3600 + 52 * 60), "4d 0h")
        XCTAssertEqual(Formatters.compactDuration(7 * 24 * 3600), "7d 0h")
        XCTAssertEqual(Formatters.compactDuration(9 * 24 * 3600 + 21 * 3600), "9d 21h")
        XCTAssertEqual(Formatters.compactDuration(5 * 3600), "5h")
        XCTAssertEqual(Formatters.compactDuration(52 * 60), "52m")
    }

    func testResetsPopoverContentResolvesEmptyCountOnlyAndTimeline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(RateLimitResetsDetail.content(count: 0, expiries: [], now: now), .empty)

        // count 있음 + expiry 목록 없음 → unknownExpiries ("no resets"로 읽히면 안 됨)
        XCTAssertEqual(
            RateLimitResetsDetail.content(count: 3, expiries: [], now: now),
            .unknownExpiries(count: 3)
        )

        let expiries = [now.addingTimeInterval(4 * 24 * 3600)]
        guard case .timeline(let entries) = RateLimitResetsDetail.content(count: 1, expiries: expiries, now: now) else {
            return XCTFail("expected timeline")
        }
        XCTAssertEqual(entries.count, 1)
    }

    func testDeadlineLabelSharesFormatAcrossPrefixesAndModes() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))!

        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600 + 360),
                                                mode: .relative, now: now), "Runs out in 2h 6m")
        XCTAssertTrue(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600),
                                               mode: .absolute, now: now, calendar: calendar)!
            .hasPrefix("Runs out today at "))
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(60),
                                                mode: .relative, now: now), "Runs out soon")
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(-1),
                                                mode: .absolute, now: now, calendar: calendar), "Runs out soon")
    }

    /// .runningOut일 때의 run-out ETA — 실제 clock 기준 평가 (아래 Date() 기반 resetsAt과 일치)
    private func runningOutEta(_ data: WidgetData) -> String? {
        if case .runningOut(let eta, _) = data.meterState() { return eta }
        return nil
    }

    func testRunningOutEtaHonorsResetDisplayMode() {
        // 10h window 절반에 90/100 사용 → run-out 약 34m 후, reset(5h)보다 이른 시점
        var data = WidgetData(title: "Session", icon: .providerMark("codex"),
                              kind: .percent, used: 90, limit: 100)
        data.resetsAt = Date().addingTimeInterval(5 * 3600)
        data.periodDurationMs = 10 * 3600 * 1000

        data.resetDisplayMode = .relative
        XCTAssertEqual(runningOutEta(data)?.hasPrefix("Limit in "), true)
        XCTAssertEqual(runningOutEta(data)?.hasSuffix("m"), true)

        data.resetDisplayMode = .absolute
        // 실제 clock 기준 평가 → 자정 부근 실행 시 "tomorrow" bucket 가능
        let absolute = runningOutEta(data)
        XCTAssertEqual(absolute?.hasPrefix("Limit today at ") == true
                        || absolute?.hasPrefix("Limit tomorrow at ") == true, true)
    }

    func testNoResetLabelWithoutResetDate() {
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"),
                              kind: .dollars, used: 12, limit: 20)
        data.resetDisplayMode = .absolute
        XCTAssertFalse(data.hasResetLabel())
        XCTAssertNil(data.resetTooltip())
        XCTAssertEqual(data.boundedTrailingText(), "$20 limit")
    }
}
