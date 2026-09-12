import Foundation
import SwiftUI
import XCTest

@testable import OpenUsage

@MainActor
final class CodexScheduledResetTests: XCTestCase {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let activeWatch =
        #"{"reset_chance_percent":75,"expires_at":"2099-01-01T00:00:00Z","source":{"url":"https://x.com/thsottiaux/status/123"}}"#

    func testScheduledResetTakesPriorityAndSkipsVotes() async throws {
        let scheduledFor = Self.now.addingTimeInterval(3_600)
        for active in ["null", Self.activeWatch] {
            let http = FakeHTTPClient(response: response(scheduledFor: scheduledFor, activeWatch: active))
            let source = CodexResetWatchStore(http: http, now: { Self.now })

            let result = await source.currentResult()
            let watch = try XCTUnwrap(result.watch)
            XCTAssertEqual(watch.chancePercent, 99)
            XCTAssertEqual(watch.deadline, scheduledFor)
            XCTAssertTrue(watch.isScheduled)
            XCTAssertNil(watch.expiresAt)
            XCTAssertNil(watch.episodeID)
            XCTAssertNil(watch.communityYesPercent)
            XCTAssertFalse(result.refreshFailed)
            XCTAssertFalse(result.isAbsent)
            XCTAssertEqual(http.requests.map(\.url.path), ["/api/v1/status"])
        }
    }

    func testNullAndPastScheduledTimesStillRepresentPendingReset() async throws {
        for scheduledFor in [nil, Self.now, Self.now.addingTimeInterval(-3_600)] as [Date?] {
            let http = FakeHTTPClient(response: response(scheduledFor: scheduledFor))
            let source = CodexResetWatchStore(http: http, now: { Self.now })

            let result = await source.currentResult()
            let watch = try XCTUnwrap(result.watch)
            XCTAssertEqual(watch.chancePercent, 99)
            XCTAssertEqual(watch.deadline, scheduledFor)
            XCTAssertTrue(watch.isScheduled)
            XCTAssertFalse(result.refreshFailed)
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testMalformedScheduledResetIsReportedAsFailure() async {
        for scheduled in [
            #"{"status":"scheduled","scheduled_for":"invalid"}"#,
            #"{"status":"scheduled","scheduled_for":123}"#,
            #"{"status":"scheduled"}"#,
            #"{"status":"completed","scheduled_for":null}"#,
        ] {
            let body = Data("{\"data\":{\"scheduled_reset\":\(scheduled),\"active_watch\":null}}".utf8)
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: body))
            let source = CodexResetWatchStore(http: http, now: { Self.now })

            let result = await source.currentResult()
            XCTAssertNil(result.watch, scheduled)
            XCTAssertTrue(result.refreshFailed, scheduled)
            XCTAssertFalse(result.isAbsent, scheduled)
        }
    }

    func testRemovingScheduleRestoresForecastOrZeroChance() async {
        for active in ["null", Self.activeWatch] {
            let http = FakeHTTPClient(response: response(scheduledFor: Self.now.addingTimeInterval(60)))
            let source = CodexResetWatchStore(http: http, now: { Self.now })
            _ = await source.currentResult()
            http.response = HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(
                    "{\"data\":{\"scheduled_reset\":null,\"active_watch\":\(active)}}".utf8
                ))

            let result = await source.currentResult(force: true)
            XCTAssertFalse(result.refreshFailed)
            XCTAssertEqual(result.isAbsent, active == "null")
            XCTAssertEqual(result.watch?.chancePercent, active == "null" ? nil : 75)
            XCTAssertNotEqual(result.watch?.isScheduled, true)
        }
    }

    func testScheduleSurvivesTimePassingRevalidationAndFailureUntilRemoved() async throws {
        let clock = ScheduledResetClock(Self.now)
        let http = FakeHTTPClient(
            response: response(
                scheduledFor: Self.now.addingTimeInterval(10),
                headers: ["etag": "schedule", "cache-control": "max-age=30"]
            ))
        let source = CodexResetWatchStore(http: http, now: clock.read)
        let initial = await source.currentResult()
        _ = try XCTUnwrap(initial.watch)
        clock.advance(by: 11)
        let cached = await source.currentResult()
        XCTAssertEqual(cached, initial)
        XCTAssertEqual(http.requests.count, 1)

        clock.advance(by: 20)
        http.response = HTTPResponse(statusCode: 304, headers: [:], body: Data())
        let revalidated = await source.currentResult()
        XCTAssertEqual(revalidated, initial)
        XCTAssertEqual(http.requests.last?.headers["If-None-Match"], "schedule")
        XCTAssertEqual(http.requests.count, 2)

        clock.advance(by: 900)
        http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        let failed = await source.currentResult()
        XCTAssertEqual(failed.watch, initial.watch)
        XCTAssertTrue(failed.refreshFailed)
        clock.advance(by: 30)
        let duringRetryDelay = await source.currentResult()
        XCTAssertEqual(duringRetryDelay, failed)
        XCTAssertEqual(http.requests.count, 3)

        clock.advance(by: 31)
        http.response = HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(
                #"{"data":{"scheduled_reset":null,"active_watch":null}}"#.utf8
            ))
        let removed = await source.currentResult()
        XCTAssertNil(removed.watch)
        XCTAssertTrue(removed.isAbsent)
        XCTAssertFalse(removed.refreshFailed)
    }

    func testScheduleHonorsNoCacheAndNoStoreOnFailedRevalidation() async {
        for policy in ["no-cache", "no-store"] {
            let http = FakeHTTPClient(
                response: response(
                    scheduledFor: Self.now, headers: ["cache-control": policy, "etag": "schedule"]
                ))
            let source = CodexResetWatchStore(http: http, now: { Self.now })
            let initial = await source.currentResult()
            XCTAssertEqual(initial.watch?.chancePercent, 99)
            http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())

            let failed = await source.currentResult()
            XCTAssertNil(failed.watch, policy)
            XCTAssertTrue(failed.refreshFailed, policy)
            XCTAssertEqual(http.requests.last?.headers["If-None-Match"], policy == "no-cache" ? "schedule" : nil)
        }
    }

    func testScheduleDisplaysTimeAnd99PercentOnDashboardAndMenuBar() async throws {
        let suiteName = "OpenUsageTests.ScheduledReset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.forecast(id: "codex.resetWatch", provider: provider, title: "Reset Watch")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [], defaults: defaults
        )
        for scheduledFor in [Self.now.addingTimeInterval(60), Self.now.addingTimeInterval(-60), nil] as [Date?] {
            let source = CodexResetWatchStore(
                http: FakeHTTPClient(response: response(scheduledFor: scheduledFor)), now: { Self.now }
            )
            let result = await source.currentResult()
            store.setCodexResetWatch(result.watch, refreshFailed: result.refreshFailed, isAbsent: result.isAbsent)
            var data = store.data(for: descriptor).presented(at: Self.now.addingTimeInterval(120))
            let expectedTime =
                scheduledFor.map { "Scheduled \(Formatters.monthDayTimeLabel($0))" }
                ?? "Reset time unknown"

            XCTAssertTrue(data.hasData)
            XCTAssertEqual(data.boundedHeadline, "99% chance")
            XCTAssertEqual(data.boundedTrailingText(), expectedTime)
            XCTAssertEqual(data.boundedSubtitle, expectedTime)
            XCTAssertNil(data.forecastDeadline)
            XCTAssertNil(data.communityVoteTick)
            XCTAssertNil(data.communityVoteLabel)
            XCTAssertFalse(data.hasResetLabel())

            for mode in [WidgetDisplayMode.used, .remaining] {
                data.displayMode = mode
                let content = MenuBarContentBuilder.build(
                    groups: [ProviderMetrics(provider: provider, metrics: [descriptor])],
                    data: { _ in data }, now: Self.now.addingTimeInterval(120)
                )
                let metric = try XCTUnwrap(content.groups.first?.metrics.first)
                XCTAssertEqual(metric.value, "99%")
                XCTAssertEqual(metric.fraction, 0.99, accuracy: 0.000_001)
                XCTAssertNil(content.nextInvalidation)
            }

            store.setCodexResetWatch(result.watch, refreshFailed: true)
            let stale = store.data(for: descriptor).presented(at: Self.now.addingTimeInterval(120))
            XCTAssertEqual(stale.boundedHeadline, "99% chance")
            XCTAssertEqual(stale.boundedTrailingText(), "Cached forecast · Refresh failed")
        }
    }

    func testScheduledLabelsWrapAtDashboardWidthInsteadOfTruncating() throws {
        let suiteName = "OpenUsageTests.ScheduledResetLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DensitySetting.regular.rawValue, forKey: DensitySetting.key)

        for label in ["Scheduled 9월 12일 at 오후 4:00", "Cached forecast · Refresh failed"] {
            var data = WidgetData(
                title: "Reset Watch", icon: .providerMark("codex"), kind: .percent, used: 99, limit: 100)
            data.forecast = .init(isScheduled: true)
            data.subtitleOverride = label

            func render(width: CGFloat) throws -> NSImage {
                try XCTUnwrap(
                    ShareCardRenderer.image(
                        for: WidgetRowView(data: data)
                            .frame(width: width)
                            .environment(\.hoverTooltipsDisabled, true)
                            .defaultAppStorage(defaults)))
            }

            let dashboard = try render(width: PanelHeightController.panelWidth - 28)
            let wide = try render(width: ShareCardView.width - 32)
            XCTAssertEqual(dashboard.size.width, PanelHeightController.panelWidth - 28)
            XCTAssertGreaterThan(dashboard.size.height, wide.size.height, label)
        }
    }

    private func response(
        scheduledFor: Date?,
        activeWatch: String = "null",
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        let dateJSON = scheduledFor.map { "\"\(OpenUsageISO8601.string(from: $0))\"" } ?? "null"
        return HTTPResponse(
            statusCode: 200, headers: headers,
            body: Data(
                """
                {"data":{"scheduled_reset":{"id":"123","status":"scheduled","reset_type":"regular",
                "scheduled_for":\(dateJSON),"source":{"url":"https://x.com/thsottiaux/status/123"}},
                "active_watch":\(activeWatch)}}
                """.utf8))
    }
}

private final class ScheduledResetClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(_ instant: Date) { self.instant = instant }

    func read() -> Date { lock.withLock { instant } }

    func advance(by interval: TimeInterval) {
        lock.withLock { instant.addTimeInterval(interval) }
    }
}
