import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetWatchResultTests: XCTestCase {
    func testSuccessfulEmptyResponseShowsZeroChanceWithoutVotes() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bodies = [
            #"{"data":{"active_watch":null}}"#,
            #"{"data":{"active_watch":{"reset_chance_percent":null,"expires_at":"2099-01-01T00:00:00Z"}}}"#,
            #"{"data":{"active_watch":{"reset_chance_percent":75,"expires_at":"2026-01-01T00:00:00Z"}}}"#
        ]
        let suiteName = "OpenUsageTests.ResetWatchResult.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.forecast(id: "codex.resetWatch", provider: provider, title: "Reset Watch")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [], defaults: defaults
        )
        XCTAssertFalse(store.data(for: descriptor).hasData)
        for body in bodies {
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8)))
            let source = CodexResetWatchStore(http: http, now: { now })
            let result = await source.currentResult()
            store.setCodexResetWatch(result.watch, refreshFailed: result.refreshFailed, isAbsent: result.isAbsent)

            let data = store.data(for: descriptor)
            XCTAssertFalse(result.refreshFailed)
            XCTAssertTrue(result.isAbsent)
            XCTAssertTrue(data.hasData)
            XCTAssertEqual(data.boundedHeadline, "0% chance")
            XCTAssertEqual(data.fraction, 0)
            XCTAssertEqual(data.menuBarValue, "0%")
            XCTAssertEqual(data.meterState(), .level(.neutral))
            XCTAssertNil(data.forecastDeadline)
            XCTAssertNil(data.boundedTrailingText())
            XCTAssertNil(data.communityVoteTick)
            XCTAssertNil(data.communityVoteLabel)
            XCTAssertEqual(http.requests.count, 1, "No active signal must not trigger a vote lookup")
        }
        store.setCodexResetWatch(nil)
        XCTAssertFalse(store.data(for: descriptor).hasData)
    }

    func testFailuresAreDistinctFromSuccessfulEmptyResponses() async {
        for (response, shouldFail) in [
            (HTTPResponse(statusCode: 503, headers: [:], body: Data()), true),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data("invalid".utf8)), true),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":{}}"#.utf8)), true),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":{"active_watch":{"reset_chance_percent":101,"expires_at":"2099-01-01T00:00:00Z"}}}"#.utf8)), true),
            (HTTPResponse(statusCode: 429, headers: [:], body: Data()), true),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":{"active_watch":null}}"#.utf8)), false)
        ] {
            let store = CodexResetWatchStore(http: FakeHTTPClient(response: response))
            let result = await store.currentResult()
            XCTAssertNil(result.watch)
            XCTAssertEqual(result.refreshFailed, shouldFail)
            XCTAssertEqual(result.isAbsent, !shouldFail)
        }
    }

    func testSuccessfulAbsenceSurvivesCacheAndRevalidationButNotFailure() async {
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: ["etag": "empty-watch", "cache-control": "max-age=60"],
            body: Data(#"{"data":{"active_watch":null}}"#.utf8)
        ))
        let source = CodexResetWatchStore(http: http)
        let initial = await source.currentResult()
        let cached = await source.currentResult()
        XCTAssertTrue(initial.isAbsent)
        XCTAssertEqual(cached, initial)
        XCTAssertEqual(http.requests.count, 1)

        http.response = HTTPResponse(statusCode: 304, headers: [:], body: Data())
        let revalidated = await source.currentResult(force: true)
        XCTAssertEqual(revalidated, initial)
        XCTAssertEqual(http.requests.last?.headers["If-None-Match"], "empty-watch")

        http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        let failed = await source.currentResult(force: true)
        XCTAssertTrue(failed.refreshFailed)
        XCTAssertFalse(failed.isAbsent)
    }

    func testCancelledCheckDoesNotBecomeSuccessfulAbsence() async {
        let source = CodexResetWatchStore(http: CancelledResetWatchHTTPClient())
        let result = await source.currentResult()
        XCTAssertEqual(result, CodexResetWatchResult())
    }

    func testCancelledRefreshPreservesReusableForecastAbsenceAndFailure() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let active = HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"data":{"active_watch":{"reset_chance_percent":75,"expires_at":"2099-01-01T00:00:00Z"}}}"#.utf8
        ))
        let absent = HTTPResponse(
            statusCode: 200, headers: [:], body: Data(#"{"data":{"active_watch":null}}"#.utf8)
        )
        let failure = HTTPResponse(statusCode: 429, headers: ["retry-after": "0"], body: Data())

        for responses in [[active], [absent], [failure], [active, failure], [absent, failure]] {
            let source = CodexResetWatchStore(
                http: CancelledResetWatchHTTPClient(responses: responses), now: { now }
            )
            var previous = CodexResetWatchResult()
            for _ in responses {
                previous = await source.currentResult(force: true)
            }

            let cancelled = await source.currentResult(force: true)
            XCTAssertEqual(cancelled, previous)
        }
    }

    func testCancelledRefreshDoesNotReuseUnvalidatedOrUnstoredResponses() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bodies = [
            #"{"data":{"active_watch":{"reset_chance_percent":75,"expires_at":"2099-01-01T00:00:00Z"}}}"#,
            #"{"data":{"active_watch":null}}"#
        ]
        for policy in ["no-cache", "no-store"] {
            for body in bodies {
                let response = HTTPResponse(
                    statusCode: 200, headers: ["cache-control": policy], body: Data(body.utf8)
                )
                let source = CodexResetWatchStore(
                    http: CancelledResetWatchHTTPClient(responses: [response]), now: { now }
                )
                _ = await source.currentResult()

                let cancelled = await source.currentResult(force: true)
                XCTAssertEqual(cancelled, CodexResetWatchResult(), policy)
            }
        }
    }

    func testCoordinatorPublishesFailureAndClearsItWhenDisabled() async {
        let published = expectation(description: "failure published")
        var result = CodexResetWatchResult()
        let coordinator = CodexResetWatchCoordinator(
            load: { _ in CodexResetWatchResult(refreshFailed: true) },
            publish: { result = $0; if $0.refreshFailed { published.fulfill() } },
            wait: { _ in false }
        )
        coordinator.setActive(true)
        await fulfillment(of: [published], timeout: 1)
        XCTAssertTrue(result.refreshFailed)
        coordinator.setActive(false)
        XCTAssertEqual(result, CodexResetWatchResult())
    }

    func testDashboardShowsFailureForEmptyAndCachedForecastsAndClearsOnSuccess() {
        let suiteName = "OpenUsageTests.ResetWatchResult.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.forecast(id: "codex.resetWatch", provider: provider, title: "Reset Watch")
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [], defaults: defaults
        )
        store.setCodexResetWatch(nil, refreshFailed: true)
        XCTAssertEqual(store.data(for: descriptor).forecast, WidgetData.Forecast(refreshFailed: true))
        XCTAssertEqual(store.data(for: descriptor).boundedTrailingText(), "Unavailable · Retry later")
        let watch = CodexResetWatch(chancePercent: 75, deadline: .distantFuture)
        store.setCodexResetWatch(watch, refreshFailed: true)
        XCTAssertEqual(store.data(for: descriptor).forecast, WidgetData.Forecast(deadline: .distantFuture, refreshFailed: true))
        XCTAssertEqual(store.data(for: descriptor).boundedTrailingText(), "Cached forecast · Refresh failed")
        XCTAssertTrue(store.data(for: descriptor).hasData)
        var withVotes = watch
        withVotes.communityYesPercent = 79
        store.setCodexResetWatch(withVotes)
        XCTAssertEqual(store.data(for: descriptor).communityVoteTick, 0.79)
        XCTAssertEqual(store.data(for: descriptor).communityVoteLabel, "79% expect a reset")
        XCTAssertEqual(store.data(for: descriptor).used, 75)
        store.setCodexResetWatch(nil, isAbsent: true)
        XCTAssertEqual(store.data(for: descriptor).forecast, WidgetData.Forecast())
        XCTAssertEqual(store.data(for: descriptor).boundedHeadline, "0% chance")
        XCTAssertNil(store.data(for: descriptor).boundedTrailingText())
        XCTAssertNil(store.data(for: descriptor).communityVoteLabel)
    }
}

private actor CancelledResetWatchHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]

    init(responses: [HTTPResponse] = []) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard !responses.isEmpty else { throw CancellationError() }
        return responses.removeFirst()
    }
}
