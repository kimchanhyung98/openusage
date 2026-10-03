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
        let executor = Executor()
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
        let executor = Executor()
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
        let executor = Executor()
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
        let executor = Executor()
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
        let executor = Executor()
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
        let executor = Executor()
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

    @MainActor
    private final class Executor: CodexWeeklyTimerExecuting {
        var auths: [CodexAuth] = []
        var beforeLaunch: (() -> Void)?
        var onLaunch: (() -> Void)?
        var afterLaunch: (@MainActor () async -> CodexWeeklyTimerExecutionResult)?

        func execute(auth: CodexAuth, canLaunch: @escaping @MainActor () async -> Bool) async -> CodexWeeklyTimerExecutionResult {
            beforeLaunch?()
            guard await canLaunch() else {
                return .init(launched: false, completed: false, updatedAuth: nil, failureDescription: "Authentication changed.")
            }
            auths.append(auth)
            onLaunch?()
            if let afterLaunch { return await afterLaunch() }
            return .init(launched: true, completed: true, updatedAuth: nil, failureDescription: nil)
        }
    }

    private struct Account {
        let provider: CodexProvider
        let files: FakeFiles
        let http: FakeHTTPClient
        let path: String
        let original: String
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
    private struct Fixture {
        let root: URL
        let store: CodexWeeklyTimerAttemptStore
        let now = Date()
        let clock: ObservationClock

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
            let http = FakeHTTPClient(response: .init(statusCode: 200, headers: [:], body: quota))
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

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
