import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetWatchResultTests: XCTestCase {
    func testFailuresAreDistinctFromSuccessfulEmptyResponses() async {
        for (response, shouldFail) in [
            (HTTPResponse(statusCode: 503, headers: [:], body: Data()), true),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data("invalid".utf8)), true),
            (HTTPResponse(statusCode: 429, headers: [:], body: Data()), true),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":{"active_watch":null}}"#.utf8)), false)
        ] {
            let store = CodexResetWatchStore(http: FakeHTTPClient(response: response))
            let result = await store.currentResult()
            XCTAssertNil(result.watch)
            XCTAssertEqual(result.refreshFailed, shouldFail)
        }
    }

    func testCoordinatorPublishesFailureAndClearsItWhenDisabled() async {
        let published = expectation(description: "failure published")
        var result = CodexResetWatchResult()
        let coordinator = CodexResetWatchCoordinator(
            load: { CodexResetWatchResult(refreshFailed: true) },
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
        XCTAssertEqual(store.data(for: descriptor).boundedTrailingText(), "Unavailable · Retry later")
        let watch = CodexResetWatch(chancePercent: 75, deadline: .distantFuture)
        store.setCodexResetWatch(watch, refreshFailed: true)
        XCTAssertEqual(store.data(for: descriptor).boundedTrailingText(), "Cached forecast · Refresh failed")
        XCTAssertTrue(store.data(for: descriptor).hasData)
        store.setCodexResetWatch(nil)
        XCTAssertEqual(store.data(for: descriptor).boundedTrailingText(), WidgetData.noDataSubtitle)
    }
}
