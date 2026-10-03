import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerRouterTests: XCTestCase {
    func testRoutesEveryEnabledAccountAndKeepsCredentialsSeparate() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.account("first", cardID: "codex")
        let second = try fixture.account("second", cardID: "codex@second")
        let disabled = try fixture.account("disabled", cardID: "codex@disabled")
        let completed = expectation(description: "Both enabled accounts finished")
        completed.expectedFulfillmentCount = 2
        let executor = fixture.executor()
        let router = CodexWeeklyTimerRouter(
            providers: [first.provider, second.provider, disabled.provider],
            isProviderEnabled: { $0 != "codex@disabled" }, executor: executor, store: fixture.store,
            report: { _, warning in XCTAssertNil(warning) },
            refresh: { _, isCurrent in XCTAssertTrue(isCurrent()); completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )

        for account in [first, second, disabled] {
            router.receive(try await fixture.changedRefresh(account, router: router), trigger: .scheduled)
        }
        await fulfillment(of: [completed], timeout: 15)

        XCTAssertEqual(Set(executor.auths.compactMap { $0.tokens?.accountID }), ["first", "second"])
        XCTAssertEqual(executor.auths.count, 2)
        XCTAssertEqual(first.files.files[first.path], first.original)
        XCTAssertEqual(second.files.files[second.path], second.original)
    }

    func testCLIAndVerificationReadsNeverTriggerMessages() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let unexpected = expectation(description: "Read-only paths must not execute")
        unexpected.isInverted = true
        executor.onLaunch = { unexpected.fulfill() }
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        var snapshot = try await fixture.changedRefresh(account, router: router)

        router.receive(snapshot, trigger: .cli)
        router.receive(snapshot, trigger: .weeklyTimer)
        snapshot.liveQuotaObservedAt = nil
        router.receive(snapshot, trigger: .manual)

        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertTrue(executor.auths.isEmpty)
    }

    func testZeroUsageWithTheSameServerResetAcrossRefreshesDoesNotLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let unexpected = expectation(description: "A fixed timer must not trigger a message")
        unexpected.isInverted = true
        executor.onLaunch = { unexpected.fulfill() }
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )

        router.receive(await account.provider.refresh(), trigger: .scheduled)
        router.receive(await account.provider.refresh(), trigger: .manual)

        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertTrue(executor.auths.isEmpty)
    }

    func testSourceChangeDuringExecutorPreparationPreventsLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let replacement = try fixture.authText("replacement")
        let executor = fixture.executor()
        executor.beforeLaunch = { account.files.files[account.path] = replacement }
        let completed = expectation(description: "Changed authentication handled")
        var warning: String?
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store,
            report: { _, message in warning = message },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )

        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertTrue(executor.auths.isEmpty)
        XCTAssertNotNil(warning)
        XCTAssertEqual(account.files.files[account.path], replacement)
    }

    func testPreparationFailureStillReportsAfterProviderClearsObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let completed = expectation(description: "Preparation failure reported")
        let executor = fixture.executor()
        var warning: String?
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store,
            report: { _, message in warning = message },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )

        let snapshot = try await fixture.changedRefresh(account, router: router)
        account.http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        router.receive(snapshot, trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertNil(account.provider.weeklyTimerObservation)
        XCTAssertNotNil(warning)
        XCTAssertTrue(executor.auths.isEmpty)
    }

    func testShutdownPersistsRotatedCredentialsBeforeReturning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        var rotated = try JSONDecoder().decode(CodexAuth.self, from: Data(account.original.utf8))
        rotated.tokens?.refreshToken = "rotated-on-cancellation"
        let executor = fixture.executor()
        executor.startupFailureDescription = "Temporary credentials could not be removed."
        executor.beforeLaunch = { [weak executor] in executor?.startupFailureDescription = nil }
        var reports: [String?] = []
        let launched = expectation(description: "Timer message launched")
        executor.onLaunch = { launched.fulfill() }
        executor.afterLaunch = {
            do { try await Task.sleep(for: .seconds(30)) } catch { }
            return .init(launched: true, completed: false, updatedAuth: rotated, failureDescription: "Cancelled.")
        }
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store,
            report: { _, message in reports.append(message) },
            refresh: { _, _ in XCTFail("Shutdown must not start a refresh") },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .scheduled)
        await fulfillment(of: [launched], timeout: 3)

        reports.removeAll()
        await router.shutdown()

        XCTAssertTrue(reports.isEmpty)
        XCTAssertFalse(router.hasPendingWork)
        let saved = try XCTUnwrap(account.files.files[account.path]).data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(CodexAuth.self, from: saved).tokens?.refreshToken, "rotated-on-cancellation")
    }

    func testUnrelatedSettingsChangeDoesNotInvalidatePreparingCodexMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let completed = expectation(description: "Timer survives unrelated settings event")
        var reports: [String?] = []
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, message in reports.append(message) },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        executor.beforeLaunch = {
            router.invalidate(providerIDs: ["claude"])
            router.invalidate()
        }

        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertEqual(reports.count, 1)
        XCTAssertNil(reports.last!)
    }

    func testChangedAccountClearsThePreviousAccountsAutomationWarning() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let completed = expectation(description: "Preparation failure handled")
        var warning: String?
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: fixture.executor(), store: fixture.store,
            report: { _, message in warning = message }, refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        let snapshot = try await fixture.changedRefresh(account, router: router)
        let response = account.http.response
        account.http.response = .init(statusCode: 503, headers: [:], body: Data())
        router.receive(snapshot, trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 1)
        XCTAssertNotNil(warning)

        account.http.response = response
        account.files.files[account.path] = try fixture.authText("replacement")
        router.receive(await account.provider.refresh(), trigger: .manual)

        XCTAssertNil(warning)
    }

    func testUnchangedCatalogIdentityPreservesRunAcrossProviderReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.account("first", cardID: "codex")
        let replacement = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let completed = expectation(description: "Unchanged account finishes across catalog rebuild")
        let identityKeys = ["codex": "workspace-first"]
        let router = CodexWeeklyTimerRouter(
            providers: [original.provider], identityKeys: identityKeys, isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, warning in XCTAssertNil(warning) },
            refresh: { _, isCurrent in XCTAssertTrue(isCurrent()); completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        executor.beforeLaunch = { router.reconfigure(providers: [replacement.provider], identityKeys: identityKeys) }

        router.receive(try await fixture.changedRefresh(original, router: router), trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 1)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertFalse(router.hasPendingWork)
    }

    func testAccountWarningsReachDuplicateCardsAndClearWhenAnotherCardSucceeds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.account("first", cardID: "codex")
        let duplicate = try fixture.account("first", cardID: "codex@duplicate")
        let late = try fixture.account("first", cardID: "codex@late")
        let disabled = try fixture.account("first", cardID: "codex@disabled")
        let other = try fixture.account("other", cardID: "codex@other")
        let executor = fixture.executor()
        let completed = expectation(description: "Another card verifies the same account")
        var warnings: [String: String] = [:]
        let router = CodexWeeklyTimerRouter(
            providers: [first, duplicate, late, disabled, other].map(\.provider),
            isProviderEnabled: { $0 != "codex@disabled" }, executor: executor, store: fixture.store,
            report: { warnings[$0] = $1 },
            refresh: { providerID, _ in
                XCTAssertEqual(providerID, "codex@duplicate")
                completed.fulfill()
            },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        for account in [first, duplicate, disabled, other] {
            router.receive(await account.provider.refresh(), trigger: .scheduled)
        }
        let saved = try Data(contentsOf: fixture.store.fileURL)
        try Data("invalid-state".utf8).write(to: fixture.store.fileURL)
        router.receive(await first.provider.refresh(), trigger: .manual)

        XCTAssertEqual(Set(warnings.keys), ["codex", "codex@duplicate"])
        XCTAssertEqual(warnings["codex"], warnings["codex@duplicate"])
        try saved.write(to: fixture.store.fileURL)
        router.receive(await late.provider.refresh(), trigger: .scheduled)
        XCTAssertEqual(warnings["codex@late"], warnings["codex"])
        XCTAssertFalse(router.hasPendingWork)

        first.files.files[first.path] = try fixture.authText("replacement")
        router.receive(await first.provider.refresh(), trigger: .manual)
        XCTAssertNil(warnings["codex"])
        XCTAssertNotNil(warnings["codex@duplicate"])
        XCTAssertNotNil(warnings["codex@late"])

        fixture.clock.advance(.seconds(300))
        router.receive(await duplicate.provider.refresh(), trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertFalse(router.hasPendingWork)
    }

    func testWarningIsForgottenWhenItsLastAccountBindingDisappears() async throws {
        for transition in 0..<4 {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let account = try fixture.account("first", cardID: "codex")
            let executor = fixture.executor()
            var warning: String?
            let router = CodexWeeklyTimerRouter(
                providers: [account.provider], isProviderEnabled: { _ in true },
                executor: executor, store: fixture.store, report: { _, message in warning = message },
                refresh: { _, _ in XCTFail("Rebinding must not send a timer message") },
                now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
            )
            let initial = await account.provider.refresh()
            router.receive(initial, trigger: .scheduled)
            let saved = try Data(contentsOf: fixture.store.fileURL)
            try Data("invalid-state".utf8).write(to: fixture.store.fileURL)
            router.receive(await account.provider.refresh(), trigger: .manual)
            XCTAssertNotNil(warning)
            try saved.write(to: fixture.store.fileURL)
            router.receive(initial, trigger: .manual)
            router.receive(.error(provider: account.provider.provider, message: "Unavailable"), trigger: .manual)
            XCTAssertNotNil(warning)

            switch transition {
            case 0: router.invalidate(providerIDs: ["codex"])
            case 1:
                router.reconfigure(providers: [])
                router.reconfigure(providers: [account.provider])
            case 2:
                account.files.files[account.path] = try fixture.authText("replacement")
                router.receive(await account.provider.refresh(), trigger: .manual)
                account.files.files[account.path] = account.original
            default:
                let response = account.http.response
                account.files.files[account.path] = try fixture.authText("replacement")
                account.http.response = .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
                let snapshot = await account.provider.refresh()
                XCTAssertNotNil(snapshot.liveQuotaObservedAt)
                XCTAssertNil(account.provider.weeklyTimerObservation)
                var cached = snapshot
                cached.liveQuotaObservedAt = nil
                router.receive(cached, trigger: .manual)
                router.receive(snapshot, trigger: .cli)
                router.receive(snapshot, trigger: .weeklyTimer)
                XCTAssertNotNil(warning)
                router.receive(snapshot, trigger: .manual)
                account.http.response = response
                account.files.files[account.path] = account.original
            }
            XCTAssertNil(warning)
            router.receive(await account.provider.refresh(), trigger: .scheduled)
            XCTAssertNil(warning)
            XCTAssertFalse(router.hasPendingWork)
            XCTAssertTrue(executor.auths.isEmpty)
        }
    }

    func testSuccessfulCleanupClearsStartupWarningsFromOtherCards() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.account("first", cardID: "codex")
        let second = try fixture.account("second", cardID: "codex@second")
        let executor = fixture.executor()
        executor.startupFailureDescription = "Temporary credentials could not be removed."
        executor.beforeLaunch = { [weak executor] in executor?.startupFailureDescription = nil }
        let completed = expectation(description: "Cleanup and message finish")
        var warnings: [String: String] = [:]
        let router = CodexWeeklyTimerRouter(
            providers: [first.provider, second.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { warnings[$0] = $1 },
            refresh: { _, _ in completed.fulfill() },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        XCTAssertEqual(Set(warnings.keys), ["codex", "codex@second"])
        router.receive(try await fixture.changedRefresh(first, router: router), trigger: .scheduled)
        await fulfillment(of: [completed], timeout: 3)

        XCTAssertEqual(executor.auths.count, 1)
        XCTAssertTrue(warnings.isEmpty)
    }

    func testFreshQuotaWithoutWeeklyDataInvalidatesPreparingAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "codex")
        let executor = fixture.executor()
        let preparing = expectation(description: "Timer waits before rechecking")
        let finished = expectation(description: "Obsolete candidate finishes")
        var resume: CheckedContinuation<Void, Never>?
        var warning: String?
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store, report: { _, message in warning = message },
            refresh: { _, _ in finished.fulfill() }, now: { fixture.clock.current() },
            wait: { _ in
                preparing.fulfill()
                await withCheckedContinuation { resume = $0 }
            }
        )
        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .scheduled)
        await fulfillment(of: [preparing], timeout: 3)
        account.files.files[account.path] = try fixture.authText("replacement")
        account.http.response = .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let snapshot = await account.provider.refresh()
        XCTAssertNotNil(snapshot.liveQuotaObservedAt)
        XCTAssertNil(account.provider.weeklyTimerObservation)
        router.receive(snapshot, trigger: .manual)
        resume?.resume()
        await fulfillment(of: [finished], timeout: 3)

        XCTAssertNil(warning)
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertTrue(executor.auths.isEmpty)
    }

}
