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
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertTrue(router.hasPendingWork(providerIDs: ["codex"]))
        XCTAssertFalse(router.isRunning(providerID: "codex"))
        let waiter = Task {
            waitStarted.fulfill()
            await router.waitForPendingWork(providerIDs: ["codex"])
            waitFinished = true
        }
        await fulfillment(of: [waitStarted], timeout: 1)
        waiter.cancel()
        XCTAssertFalse(waitFinished)
        XCTAssertFalse(refreshFinished)

        releaseRefresh?.resume()
        await waiter.value
        XCTAssertTrue(waitFinished)
        XCTAssertTrue(refreshFinished)
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertFalse(router.hasPendingWork(providerIDs: ["codex"]))
        XCTAssertEqual(executor.auths.count, 1)
    }

    func testFollowUpRefreshDoesNotBlockNextAccountOrUnrelatedCompletion() async throws {
        let fixture = try CodexWeeklyTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let first = try fixture.account("first", cardID: "codex")
        let second = try fixture.account("second", cardID: "codex@second")
        let executor = fixture.executor()
        let refreshesStarted = expectation(description: "Both follow-up refreshes started")
        refreshesStarted.expectedFulfillmentCount = 2
        let waitStarted = expectation(description: "Selected account waiter started")
        let waitCompleted = expectation(description: "Selected account waiter completed")
        let shutdownCompleted = expectation(description: "Shutdown completed before unrelated refresh")
        var releases: [String: CheckedContinuation<Void, Never>] = [:]
        var finished: Set<String> = []
        var waitFinished = false
        let router = CodexWeeklyTimerRouter(
            providers: [first.provider, second.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
            refresh: { providerID, _ in
                await withCheckedContinuation {
                    releases[providerID] = $0
                    refreshesStarted.fulfill()
                }
                XCTAssertFalse(Task.isCancelled)
                finished.insert(providerID)
            },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        let firstSnapshot = try await fixture.changedRefresh(first, router: router)
        let secondSnapshot = try await fixture.changedRefresh(second, router: router)
        router.receive(firstSnapshot, trigger: .accountChange)
        router.receive(secondSnapshot, trigger: .accountChange)
        await fulfillment(of: [refreshesStarted], timeout: 3)
        XCTAssertEqual(executor.auths.compactMap { $0.tokens?.accountID }, ["first", "second"])
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertTrue(router.hasPendingWork(providerIDs: ["codex@second"]))

        let waiter = Task {
            waitStarted.fulfill()
            await router.waitForPendingWork(providerIDs: ["codex"])
            waitFinished = true
            waitCompleted.fulfill()
        }
        await fulfillment(of: [waitStarted], timeout: 1)
        XCTAssertFalse(waitFinished)
        releases["codex"]?.resume()
        await fulfillment(of: [waitCompleted], timeout: 1)
        XCTAssertTrue(waitFinished)
        XCTAssertEqual(finished, ["codex"])
        XCTAssertFalse(router.hasPendingWork(providerIDs: ["codex"]))
        XCTAssertTrue(router.hasPendingWork(providerIDs: ["codex@second"]))

        let shutdown = Task {
            await router.shutdown()
            shutdownCompleted.fulfill()
        }
        await fulfillment(of: [shutdownCompleted], timeout: 1)
        XCTAssertEqual(finished, ["codex"])
        releases["codex@second"]?.resume()
        await waiter.value
        await shutdown.value
        await router.waitForPendingWork(providerIDs: ["codex@second"])
        XCTAssertEqual(finished, ["codex", "codex@second"])
    }
}
