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
        let launched = expectation(description: "Timer message launched")
        executor.onLaunch = { launched.fulfill() }
        executor.afterLaunch = {
            do { try await Task.sleep(for: .seconds(30)) } catch { }
            return .init(launched: true, completed: false, updatedAuth: rotated, failureDescription: "Cancelled.")
        }
        let router = CodexWeeklyTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store,
            report: { _, _ in XCTFail("Shutdown must not publish an old result") },
            refresh: { _, _ in XCTFail("Shutdown must not start a refresh") },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) }
        )
        router.receive(try await fixture.changedRefresh(account, router: router), trigger: .scheduled)
        await fulfillment(of: [launched], timeout: 3)

        await router.shutdown()

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

    @MainActor
    private final class Executor: CodexWeeklyTimerExecuting {
        var auths: [CodexAuth] = []
        var didAuthenticate: ((CodexAuth) -> Void)?
        var beforeLaunch: (() -> Void)?
        var onLaunch: (() -> Void)?
        var afterLaunch: (@MainActor () async -> CodexWeeklyTimerExecutionResult)?

        func execute(auth: CodexAuth, canLaunch: @escaping @MainActor () async -> Bool) async -> CodexWeeklyTimerExecutionResult {
            beforeLaunch?()
            guard await canLaunch() else {
                return .init(launched: false, completed: false, updatedAuth: nil, failureDescription: "Authentication changed.")
            }
            auths.append(auth)
            didAuthenticate?(auth)
            onLaunch?()
            if let afterLaunch { return await afterLaunch() }
            return .init(launched: true, completed: true, updatedAuth: nil, failureDescription: nil)
        }
    }

    private struct Account {
        let provider: CodexProvider
        let files: FakeFiles
        let http: TimerHTTPClient
        let path: String
        let original: String
    }

    private final class TimerHTTPClient: HTTPClient, @unchecked Sendable {
        var response: HTTPResponse {
            didSet { updatedAt = clock.current() }
        }
        private let clock: ObservationClock
        private var updatedAt: Date
        private var running = false

        init(response: HTTPResponse, clock: ObservationClock) {
            self.response = response
            self.clock = clock
            updatedAt = clock.current()
        }

        func startTimer() {
            response = currentResponse()
            running = true
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse { currentResponse() }

        private func currentResponse() -> HTTPResponse {
            guard !running, response.statusCode == 200,
                  var body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  var limit = body["rate_limit"] as? [String: Any],
                  var window = limit["secondary_window"] as? [String: Any],
                  let reset = window["reset_at"] as? Double else { return response }
            window["reset_at"] = reset + clock.current().timeIntervalSince(updatedAt)
            limit["secondary_window"] = window
            body["rate_limit"] = limit
            return .init(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: body))
        }
    }

    private final class ObservationClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) { self.date = date }

        func current() -> Date { lock.withLock { date } }

        func advance(_ duration: Duration) {
            lock.withLock {
                date = date.addingTimeInterval(Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18)
            }
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            date = date.addingTimeInterval(1)
            return date
        }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let store: CodexWeeklyTimerAttemptStore
        let now = Date()
        let clock: ObservationClock
        private var clients: [String: TimerHTTPClient] = [:]

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("OpenUsage.RouterTests.\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = CodexWeeklyTimerAttemptStore(fileURL: root.appendingPathComponent("attempts.json"))
            clock = ObservationClock(now)
        }

        func account(_ id: String, cardID: String) throws -> Account {
            let now = self.now
            let clock = self.clock
            let path = "/router-fixture/\(id)/auth.json"
            let original = try authText(id)
            let files = FakeFiles([path: original])
            let quota = try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["secondary_window": [
                    "used_percent": 0, "limit_window_seconds": 604_800,
                    "reset_at": now.addingTimeInterval(604_800).timeIntervalSince1970
                ]]
            ])
            let http = TimerHTTPClient(response: .init(statusCode: 200, headers: [:], body: quota), clock: clock)
            clients[id] = http
            let provider = CodexProvider(
                provider: CodexProvider.makeProvider(id: cardID),
                authStore: CodexAuthStore(
                    environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                    scope: .home(path: "/router-fixture/\(id)"), now: { now }
                ),
                usageClient: CodexUsageClient(http: http),
                logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: "timer-router-\(id)", rootsOverride: []),
                includePiUsage: false, now: { clock.next() }, pricing: { .empty }
            )
            return Account(provider: provider, files: files, http: http, path: path, original: original)
        }

        func changedRefresh(_ account: Account, router: CodexWeeklyTimerRouter) async throws -> ProviderSnapshot {
            let current = account.http.response
            let previous = try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["secondary_window": [
                    "used_percent": 0, "limit_window_seconds": 604_800,
                    "reset_at": now.addingTimeInterval(604_500).timeIntervalSince1970
                ]]
            ])
            account.http.response = .init(statusCode: 200, headers: [:], body: previous)
            router.receive(await account.provider.refresh(), trigger: .scheduled)
            account.http.response = current
            let snapshot = await account.provider.refresh()
            let preparation = try JSONSerialization.data(withJSONObject: [
                "rate_limit": ["secondary_window": [
                    "used_percent": 0, "limit_window_seconds": 604_800,
                    "reset_at": now.addingTimeInterval(605_100).timeIntervalSince1970
                ]]
            ])
            account.http.response = .init(statusCode: 200, headers: [:], body: preparation)
            return snapshot
        }

        func authText(_ id: String) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: [
                "sub": "subject-\(id)", "exp": now.addingTimeInterval(3_600).timeIntervalSince1970,
                "https://api.openai.com/auth": ["chatgpt_account_id": id]
            ]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let auth = CodexAuth(tokens: .init(accessToken: "e30.\(payload).signature", refreshToken: "refresh-\(id)", accountID: id))
            return String(decoding: try JSONEncoder().encode(auth), as: UTF8.self)
        }

        func executor() -> Executor {
            let executor = Executor()
            executor.didAuthenticate = { [self] auth in
                if let account = auth.tokens?.accountID { clients[account]?.startTimer() }
            }
            return executor
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
