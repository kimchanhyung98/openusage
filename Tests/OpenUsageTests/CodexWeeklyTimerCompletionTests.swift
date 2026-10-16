import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerCompletionTests: XCTestCase {
    func testAccountChangeWaitIncludesFollowUpRefresh() async throws {
        let fixture = try CodexWeeklyTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let refreshStarted = expectation(description: "Follow-up refresh started")
        let waitStarted = expectation(description: "Completion waiter started")
        var releaseRefresh: CheckedContinuation<Void, Never>?
        var refreshFinished = false
        var waitFinished = false
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
            refresh: { providerID, isCurrent in
                XCTAssertEqual(providerID, "codex")
                XCTAssertTrue(isCurrent())
                await withCheckedContinuation {
                    releaseRefresh = $0
                    refreshStarted.fulfill()
                }
                XCTAssertTrue(isCurrent())
                refreshFinished = true
            },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .accountChange)
        await fulfillment(of: [refreshStarted], timeout: 3)
        XCTAssertTrue(router.hasPendingWork)
        XCTAssertFalse(router.isRunning(providerID: "codex"))
        let waiter = Task {
            waitStarted.fulfill()
            await router.waitForPendingWork()
            waitFinished = true
        }
        await fulfillment(of: [waitStarted], timeout: 1)
        XCTAssertFalse(waitFinished)
        XCTAssertFalse(refreshFinished)

        releaseRefresh?.resume()
        await waiter.value
        XCTAssertTrue(waitFinished)
        XCTAssertTrue(refreshFinished)
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertEqual(executor.auths.count, 1)
    }
}
