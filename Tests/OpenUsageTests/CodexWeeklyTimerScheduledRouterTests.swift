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
        router.receive(await account.provider.refresh(), trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertEqual(try fixture.store.attempt(for: observation.accountKey)?.execution, .completed)
        await router.shutdown()
        XCTAssertTrue(router.requestScheduledCheck().isEmpty)
    }

    func testBackwardClockChangeDoesNotDiscardFreshTimerChecksUntilClockCatchesUp() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let completed = expectation(description: "Timer checked after backward clock change")
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, _ in },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        let snapshot = await account.provider.refresh()
        let observation = try XCTUnwrap(account.provider.weeklyTimerObservation)
        _ = try fixture.store.observe(
            accountKey: observation.accountKey, rawResetAt: fixture.now.addingTimeInterval(3 * 86_400),
            observedAt: observation.observedAt, usedPercent: 40
        )
        fixture.clock.advance(.seconds(-7_200))
        XCTAssertEqual(router.requestScheduledCheck(), ["codex"])
        router.receive(snapshot, trigger: .scheduled)
        router.receive(await account.provider.refresh(), trigger: .weeklyTimerCheck)
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(fixture.store.latestObservationAt(accountKey: observation.accountKey)),
                             fixture.now.addingTimeInterval(-7_200))
        XCTAssertLessThan(try XCTUnwrap(fixture.store.latestObservationAt(accountKey: observation.accountKey)),
                          observation.observedAt)
        await router.shutdown()
    }

    func testResponseStartedBeforeClockRollbackCannotRestoreFutureObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let lateAccount = try fixture.account("first", cardID: "codex@late")
        let executor = fixture.executor()
        let completed = expectation(description: "Fresh timer check completed")
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider, lateAccount.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, _ in },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        let lateSnapshot = await lateAccount.provider.refresh()
        let oldObservation = try XCTUnwrap(lateAccount.provider.weeklyTimerObservation)
        _ = try fixture.store.observe(
            accountKey: oldObservation.accountKey, rawResetAt: fixture.now.addingTimeInterval(3 * 86_400),
            observedAt: oldObservation.observedAt, usedPercent: 40
        )
        fixture.clock.advance(.seconds(-7_200))
        router.receive(await account.provider.refresh(), trigger: .manual)
        await fulfillment(of: [completed], timeout: 1)
        let latest = try fixture.store.latestObservationAt(accountKey: oldObservation.accountKey)

        router.receive(lateSnapshot, trigger: .scheduled)

        XCTAssertEqual(try fixture.store.latestObservationAt(accountKey: oldObservation.accountKey), latest)
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertEqual(executor.auths.count, 1)
        await router.shutdown()
    }

    func testSuccessfulStateReadClearsWarningForFixedAndNonzeroUsage() async throws {
        for usedPercent in [0, 15] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let account = try fixture.account("first", cardID: "codex")
            let executor = fixture.executor()
            let quota = try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["secondary_window": [
                    "used_percent": usedPercent, "limit_window_seconds": 604_800,
                    "reset_at": fixture.now.addingTimeInterval(604_800).timeIntervalSince1970
                ]]
            ])
            account.http.response = .init(statusCode: 200, headers: [:], body: quota)
            account.http.startTimer()
            var warning: String?
            let router = CodexWeeklyTimerRouter(
                providers: [account.provider], isProviderEnabled: { _ in true },
                executor: executor, store: fixture.store, report: { _, message in warning = message },
                refresh: { _, _ in XCTFail("A recovered fixed timer must not send") },
                now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
            )
            router.receive(await account.provider.refresh(), trigger: .scheduled)
            fixture.clock.advance(.seconds(65))
            router.receive(await account.provider.refresh(), trigger: .scheduled)
            let saved = try Data(contentsOf: fixture.store.fileURL)
            try Data("invalid-state".utf8).write(to: fixture.store.fileURL)
            router.receive(await account.provider.refresh(), trigger: .manual)
            XCTAssertTrue(warning?.contains("could not read its saved state") == true)

            try saved.write(to: fixture.store.fileURL)
            router.receive(await account.provider.refresh(), trigger: .scheduled)

            XCTAssertNil(warning, "Recovered state must clear at \(usedPercent)% usage")
            XCTAssertFalse(router.hasPendingWork)
            XCTAssertTrue(executor.auths.isEmpty)
            await router.shutdown()
        }
    }

    func testClockNotificationInvalidatesPreSendVerificationWithoutAnotherSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let completed = expectation(description: "Interrupted verification finishes")
        var waitCount = 0
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, _ in },
            refresh: { _, _ in completed.fulfill() }, now: { fixture.clock.current() },
            wait: { duration in
                waitCount += 1
                if waitCount == 1 {
                    fixture.clock.advance(.seconds(90))
                    fixture.clock.advance(.seconds(-1))
                    NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
                } else {
                    fixture.clock.advance(duration)
                }
            }
        )
        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .weeklyTimerCheck)
        let accountKey = try XCTUnwrap(account.provider.weeklyTimerObservation?.accountKey)
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertTrue(executor.auths.isEmpty)
        XCTAssertNil(try fixture.store.attempt(for: accountKey))
        XCTAssertEqual(waitCount, 1)
        await router.shutdown()
    }

    func testClockRecoveryDuringExecutorPreparationPreventsLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let completed = expectation(description: "Invalidated launch finishes")
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, _ in },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        executor.beforeLaunch = {
            fixture.clock.advance(.seconds(-7_200))
            router.receive(await account.provider.refresh(), trigger: .manual)
        }
        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .weeklyTimerCheck)
        let accountKey = try XCTUnwrap(account.provider.weeklyTimerObservation?.accountKey)
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertTrue(executor.auths.isEmpty)
        XCTAssertEqual(try fixture.store.attempt(for: accountKey)?.execution, .failed)
        XCTAssertFalse(try fixture.store.canAttempt(accountKey: accountKey, now: fixture.clock.current()))
        executor.beforeLaunch = nil
        await router.shutdown()
    }
}
