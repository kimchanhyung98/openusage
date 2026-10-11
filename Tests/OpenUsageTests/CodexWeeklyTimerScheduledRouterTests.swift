import XCTest
@testable import OpenUsage

@MainActor
extension CodexWeeklyTimerRouterTests {
    func testUsageRefreshesRecheckMovingTimers() async throws {
        for trigger: RefreshTrigger in [.scheduled, .manual, .accountChange, .credentialChange, .resetClaim] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let account = try fixture.account("first", cardID: "codex")
            let executor = fixture.executor()
            let completed = expectation(description: "Timer checked after \(trigger.rawValue)")
            let router = CodexWeeklyTimerRouter(
                providers: [account.provider], isProviderEnabled: { _ in true },
                executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
                refresh: { _, _ in completed.fulfill() },
                now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
            )
            let snapshot = try await fixture.changedRefresh(account, router: router)
            router.receive(snapshot, trigger: trigger)
            await fulfillment(of: [completed], timeout: 1)

            XCTAssertFalse(router.hasPendingWork, trigger.rawValue)
            XCTAssertEqual(executor.auths.count, 1, trigger.rawValue)
            await router.shutdown()
        }
    }

    func testQuarterHourChecksSkipExtraReadsUntilAZeroUsageResetMoves() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        account.http.startTimer()
        let completed = expectation(description: "Reset after a fixed timer detected")
        var resetExpected = false
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
            refresh: { _, _ in
                XCTAssertTrue(resetExpected, "A fixed timer needs no follow-up refresh")
                completed.fulfill()
            },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        router.receive(await account.provider.refresh(), trigger: .scheduled)
        for index in 1...2 {
            fixture.clock.advance(.seconds(900))
            XCTAssertEqual(router.requestScheduledCheck(), ["codex"])
            router.receive(await account.provider.refresh(), trigger: .weeklyTimerCheck)
            XCTAssertFalse(router.hasPendingWork)
            XCTAssertTrue(executor.auths.isEmpty)
            XCTAssertEqual(account.http.usageRequestCount, index + 1)
        }
        resetExpected = true
        account.http.resetTimer()
        fixture.clock.advance(.seconds(900))
        XCTAssertEqual(router.requestScheduledCheck(), ["codex"])
        router.receive(await account.provider.refresh(), trigger: .weeklyTimerCheck)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertEqual(executor.auths.count, 1)
        await router.shutdown()
    }

    func testFixedTimerClearsPreparationFailureWithoutExtraReads() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let response = account.http.response
        let executor = fixture.executor()
        let failed = expectation(description: "Preparation failed")
        var warning: String?
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, message in warning = message },
            refresh: { _, _ in failed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        let snapshot = try await fixture.changedRefresh(account, router: router)
        account.http.response = .init(statusCode: 503, headers: [:], body: Data())
        router.receive(snapshot, trigger: .weeklyTimerCheck)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertNotNil(warning)

        account.http.response = response
        account.http.startTimer()
        fixture.clock.advance(.seconds(300))
        let reads = account.http.usageRequestCount
        router.receive(await account.provider.refresh(), trigger: .manual)

        XCTAssertFalse(router.hasPendingWork)
        XCTAssertEqual(account.http.usageRequestCount, reads + 1)
        XCTAssertTrue(executor.auths.isEmpty)
        XCTAssertNil(warning)
        await router.shutdown()
    }

    func testNormalRefreshDetectsEarlyResetDespitePreviousConfirmation() async throws {
        for trigger: RefreshTrigger in [.scheduled, .manual, .resetClaim] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let account = try fixture.account("first", cardID: "codex")
            let executor = fixture.executor()
            let completed = expectation(description: "Early reset checked after \(trigger.rawValue)")
            let router = CodexWeeklyTimerRouter(
                providers: [account.provider], isProviderEnabled: { _ in true },
                executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
                refresh: { _, _ in completed.fulfill() },
                now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
            )
            let snapshot = await account.provider.refresh()
            let observation = try XCTUnwrap(account.provider.weeklyTimerObservation)
            _ = try fixture.store.observe(accountKey: observation.accountKey,
                                          rawResetAt: fixture.now.addingTimeInterval(3 * 86_400),
                                          observedAt: fixture.now.addingTimeInterval(-3_600), usedPercent: 40)

            router.receive(snapshot, trigger: trigger)
            await fulfillment(of: [completed], timeout: 1)

            XCTAssertEqual(executor.auths.count, 1)
            await router.shutdown()
        }
    }

    func testManualAndScheduledRefreshRetryPreparationFailure() async throws {
        for trigger: RefreshTrigger in [.manual, .scheduled] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let account = try fixture.account("first", cardID: "codex")
            let executor = fixture.executor()
            let failed = expectation(description: "Initial preparation failed")
            let retried = expectation(description: "Preparation retried on \(trigger.rawValue)")
            var completions = 0
            var warning: String?
            let router = CodexWeeklyTimerRouter(
                providers: [account.provider], isProviderEnabled: { _ in true },
                executor: executor, store: fixture.store, report: { _, message in warning = message },
                refresh: { _, _ in
                    completions += 1
                    if completions == 1 { failed.fulfill() } else { retried.fulfill() }
                },
                now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
            )
            let response = account.http.response
            let snapshot = try await fixture.changedRefresh(account, router: router)
            account.http.response = .init(statusCode: 503, headers: [:], body: Data())
            router.receive(snapshot, trigger: .weeklyTimerCheck)
            await fulfillment(of: [failed], timeout: 1)
            XCTAssertTrue(warning?.contains("Refresh to try again") == true)
            XCTAssertTrue(executor.auths.isEmpty)

            account.http.response = response
            if trigger == .scheduled { fixture.clock.advance(.seconds(300)) }
            router.receive(await account.provider.refresh(), trigger: trigger)
            await fulfillment(of: [retried], timeout: 1)

            XCTAssertEqual(executor.auths.count, 1)
            XCTAssertNil(warning)
            await router.shutdown()
        }
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
