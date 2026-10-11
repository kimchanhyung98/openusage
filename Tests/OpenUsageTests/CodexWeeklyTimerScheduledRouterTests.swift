import XCTest
@testable import OpenUsage

@MainActor
extension CodexWeeklyTimerRouterTests {
    func testUsageRefreshesDoNotScheduleTimerChecks() async throws {
        for trigger: RefreshTrigger in [.scheduled, .manual, .accountChange, .credentialChange, .resetClaim] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let account = try fixture.account("first", cardID: "codex")
            let executor = fixture.executor()
            let router = CodexWeeklyTimerRouter(
                providers: [account.provider], isProviderEnabled: { _ in true },
                executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
                refresh: { _, _ in XCTFail("Usage refresh must not start timer work") },
                now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
            )
            let snapshot = try await fixture.changedRefresh(account, router: router)
            let observation = try XCTUnwrap(account.provider.weeklyTimerObservation)

            router.receive(snapshot, trigger: trigger)

            XCTAssertFalse(router.hasPendingWork, trigger.rawValue)
            XCTAssertTrue(executor.auths.isEmpty, trigger.rawValue)
            XCTAssertEqual(try fixture.store.latestObservationAt(accountKey: observation.accountKey),
                           observation.observedAt)
            await router.shutdown()
        }
    }

    func testQuarterHourCheckStartsAfterReadOnlyFiveMinuteRefreshes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let completed = expectation(description: "Quarter-hour timer check completed")
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        for _ in 0..<3 {
            router.receive(await account.provider.refresh(), trigger: .scheduled)
            XCTAssertFalse(router.hasPendingWork)
            XCTAssertTrue(executor.auths.isEmpty)
            fixture.clock.advance(.seconds(300))
        }

        router.receive(await account.provider.refresh(), trigger: .weeklyTimerCheck)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertFalse(router.hasPendingWork)
        await router.shutdown()
    }

    func testPendingScheduledCheckRevalidatesNextFreshScheduledSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let disabled = try fixture.account("disabled", cardID: "codex@disabled")
        let executor = fixture.executor()
        let completed = expectation(description: "Scheduled revalidation finished")
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider, disabled.provider], isProviderEnabled: { $0 == "codex" },
            executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        let snapshot = await account.provider.refresh()
        let observation = try XCTUnwrap(account.provider.weeklyTimerObservation)
        _ = try fixture.store.observe(accountKey: observation.accountKey,
                                      rawResetAt: fixture.now.addingTimeInterval(3 * 86_400),
                                      observedAt: fixture.now.addingTimeInterval(-3_600), usedPercent: 40)

        XCTAssertEqual(router.requestScheduledCheck(), ["codex"])
        router.receive(snapshot, trigger: .cli)
        XCTAssertFalse(router.hasPendingWork)
        router.receive(snapshot, trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertEqual(try fixture.store.attempt(for: observation.accountKey)?.execution, .completed)
        await router.shutdown()
        XCTAssertTrue(router.requestScheduledCheck().isEmpty)
    }
}
