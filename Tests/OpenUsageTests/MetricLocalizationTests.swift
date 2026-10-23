import XCTest
@testable import OpenUsage

final class MetricLocalizationTests: XCTestCase {
    func testAutoTimePreservesSystemHourCycleAndLocalizesDayPeriod() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 17, minute: 30)))
        let twelveHourSystem = Locale(identifier: "en_US")
        let twentyFourHourSystem = Locale(identifier: "en_GB")

        let korean = TimeFormatSetting.auto.shortTime(date, base: Locale(identifier: "ko_KR"), systemLocale: twelveHourSystem)
        XCTAssertTrue(korean.contains("오후"))
        XCTAssertTrue(korean.contains("5:30"))
        let english = TimeFormatSetting.auto.shortTime(date, base: Locale(identifier: "en_US"), systemLocale: twentyFourHourSystem)
        XCTAssertEqual(english, "17:30")

        let explicitTwentyFour = TimeFormatSetting.twentyFourHour.shortTime(date, base: Locale(identifier: "en_US"), systemLocale: twelveHourSystem)
        XCTAssertEqual(explicitTwentyFour, "17:30")
        let explicitTwelve = TimeFormatSetting.twelveHour.shortTime(date, base: Locale(identifier: "en_US"), systemLocale: twentyFourHourSystem)
        XCTAssertTrue(explicitTwelve.contains("PM"))
        XCTAssertTrue(explicitTwelve.contains("5:30"))
    }

    @MainActor
    func testGrokCapPresentationSurvivesCacheWithoutChangingTheBadge() throws {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-06-15T00:00:00Z","end":"2026-06-22T00:00:00Z"},"onDemandCap":{"val":2500}}}"#.utf8))
        let mapped = try GrokUsageMapper.mapCreditsConfig(response)
        let provider = Provider(id: "grok", displayName: "Grok", icon: .providerMark("grok"))
        let descriptor = WidgetDescriptor.badge(id: "grok.payAsYouGo", provider: provider, title: "Extra Usage", metricLabel: "Pay as you go")
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: mapped.lines, refreshedAt: Date(),
            metricPresentations: mapped.metricPresentations
        )
        let cached = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        guard case .badge(_, let canonicalText, _, _) = cached.line(label: "Pay as you go") else {
            return XCTFail("expected the original badge")
        }
        XCTAssertEqual(canonicalText, "2500 cap")

        let suiteName = "MetricLocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let runtime = TestProviderRuntime(provider: provider, descriptors: [descriptor], snapshot: cached)
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime], defaults: defaults
        )
        store.snapshots[provider.id] = cached
        L10n.withLanguage(.korean) {
            XCTAssertEqual(store.data(for: descriptor).valueText, "한도 2500")
            XCTAssertEqual(store.data(for: descriptor).menuBarValue, "한도 2500")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(store.data(for: descriptor).valueText, "上限 2500")
        }
        L10n.withLanguage(.english) {
            XCTAssertEqual(store.data(for: descriptor).valueText, "2500 cap")
        }
    }

    func testLocalizedWidgetKeepsCanonicalTitleAndMetricIdentity() {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.percent(id: "claude.session", provider: provider, title: "Session")
        var data = descriptor.sample
        data.used = 42

        L10n.withLanguage(.korean) {
            XCTAssertEqual(data.title, "Session")
            XCTAssertEqual(data.localizedTitle, "세션")
            XCTAssertEqual(data.boundedHeadline, "42% 사용")
            XCTAssertEqual(descriptor.metricLabel, "Session")
            XCTAssertEqual(descriptor.id, "claude.session")
            XCTAssertEqual(TotalSpendPeriod.today.lineLabel, "Today")
            XCTAssertEqual(TotalSpendPeriod.today.rawValue, "Today")
            XCTAssertEqual(TotalSpendPeriod.today.shortLabel, "오늘")
        }

        data.displayMode = .remaining
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(data.localizedTitle, "セッション")
            XCTAssertEqual(data.boundedHeadline, "残り 58%")
            XCTAssertEqual(data.meterStyleTooltip, "42% 使用済み")
        }
    }

    func testAmountsKeepUSDAndUseLocalizedUnitsAndSentenceOrder() {
        let credits = MetricValue(number: 772, kind: .count, label: "credits")
        L10n.withLanguage(.korean) {
            XCTAssertEqual(MetricFormatter.string(for: credits, style: .row), "772 크레딧")
            XCTAssertEqual(MetricFormatter.number(2059.07, kind: .dollars, style: .full), "$2,059.07")
            XCTAssertEqual(MetricFormatter.usageValue("$12.00", word: "spent"), "$12.00 지출")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(MetricFormatter.usageValue("$12.00", word: "left"), "残り $12.00")
            XCTAssertEqual(MetricFormatter.labelledValue("3", label: "tokens"), "3 トークン")
        }
        XCTAssertEqual(credits.label, "credits")
    }

    func testResetSentencesUseLocalizedDurationAndWordOrder() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        L10n.withLanguage(.korean) {
            XCTAssertEqual(Formatters.resetRelativeLabel(until: now.addingTimeInterval(3600), now: now), "1시간 후 초기화")
            XCTAssertEqual(Formatters.deadlineLabel("Limit", at: now.addingTimeInterval(3600), mode: .relative, now: now), "1시간 후 한도 도달")
            XCTAssertEqual(Formatters.compactDuration(4 * 24 * 3600), "4일 0시간")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertEqual(Formatters.resetRelativeLabel(until: now.addingTimeInterval(3600), now: now), "1時間後にリセット")
        }
        L10n.withLanguage(.english) {
            XCTAssertEqual(Formatters.resetRelativeLabel(until: now.addingTimeInterval(3600), now: now), "Resets in 1h")
        }
    }

    func testTrendMapperKeepsCanonicalDateWhileDisplayUsesTheSelectedLanguage() throws {
        let now = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12)))
        let day = Calendar.current.startOfDay(for: now)
        let series = DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 1500, costUSD: nil)
        ])
        let canonicalLabel = Formatters.monthDayLabel(day, locale: .current)

        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                var lines: [MetricLine] = []
                SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: "From your Claude logs (estimated)")
                guard case .chart(let label, let points, _) = lines.first else {
                    return XCTFail("expected a chart line")
                }
                let point = try XCTUnwrap(points.last)
                XCTAssertEqual(label, "Usage Trend")
                XCTAssertEqual(point.label, canonicalLabel)
                XCTAssertEqual(point.date, day)
                XCTAssertEqual(point.valueLabel, "1.5K tokens")
                switch language {
                case .english:
                    XCTAssertEqual(point.localizedLabel, "Jun 21")
                    XCTAssertEqual(point.localizedReadout, "1.5K tokens")
                case .korean:
                    XCTAssertEqual(point.localizedLabel, "6월 21일")
                    XCTAssertEqual(point.localizedReadout, "1.5K 토큰")
                case .japanese:
                    XCTAssertEqual(point.localizedLabel, "6月21日")
                    XCTAssertEqual(point.localizedReadout, "1.5K トークン")
                }
            }
        }
    }

    func testChartDisplayUsesRawDateAndCountWithoutChangingCachedStrings() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let point = MetricChartPoint(value: 1500, label: "Legacy Date", valueLabel: "1.5K tokens", date: date)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(MetricChartPoint.self, from: data)
        XCTAssertEqual(decoded, point)

        L10n.withLanguage(.korean) {
            XCTAssertTrue(decoded.localizedLabel.contains("월"))
            XCTAssertEqual(decoded.localizedReadout, "1.5K 토큰")
            XCTAssertEqual(decoded.label, "Legacy Date")
            XCTAssertEqual(decoded.valueLabel, "1.5K tokens")
        }
        L10n.withLanguage(.japanese) {
            XCTAssertTrue(decoded.localizedLabel.contains("月"))
            XCTAssertEqual(decoded.localizedReadout, "1.5K トークン")
        }

        let legacy = Data(#"{"value":1500,"label":"Jun 20","valueLabel":"1.5K tokens"}"#.utf8)
        let oldPoint = try JSONDecoder().decode(MetricChartPoint.self, from: legacy)
        XCTAssertNil(oldPoint.date)
        XCTAssertEqual(oldPoint.localizedLabel, "Jun 20")
    }

    func testLocalUsageAPIKeepsEnglishValueAndOriginalChartShapeInEveryLanguage() throws {
        let point = MetricChartPoint(value: 1500, label: "Jun 20", valueLabel: "1.5K tokens", date: Date())
        let snapshot = ProviderSnapshot(
            providerID: "claude", displayName: "Claude",
            lines: [
                .values(label: "Today", values: [
                    MetricValue(number: 5.17, kind: .dollars),
                    MetricValue(number: 1500, kind: .count, label: "tokens")
                ]),
                .chart(label: "Usage Trend", points: [point], note: "From your Claude logs (estimated)")
            ]
        )
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["claude"], knownIDs: ["claude"], snapshots: ["claude": snapshot])

        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                let response = LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state)
                let object = try XCTUnwrap((try JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [[String: Any]])?.first)
                let lines = try XCTUnwrap(object["lines"] as? [[String: Any]])
                XCTAssertEqual(lines[0]["label"] as? String, "Today")
                XCTAssertEqual(lines[0]["value"] as? String, "$5.17 · 1.5K tokens")
                let wirePoint = try XCTUnwrap((lines[1]["points"] as? [[String: Any]])?.first)
                XCTAssertEqual(Set(wirePoint.keys), Set(["value", "label", "valueLabel"]))
                XCTAssertEqual(wirePoint["label"] as? String, "Jun 20")
                XCTAssertEqual(wirePoint["valueLabel"] as? String, "1.5K tokens")
            }
        }
    }
}
