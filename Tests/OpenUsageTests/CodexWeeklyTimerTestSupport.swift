import Foundation
@testable import OpenUsage

@MainActor
final class WeeklyTimerProbe {
    let directory: URL
    let store: CodexWeeklyTimerAttemptStore
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var bindings: [String: UUID] = ["codex": UUID()]
    var accounts: [String: String] = ["codex": "a"]
    var enabled = true
    var preparationUsed = 0.0
    var preparationReset: Date? = Date(timeIntervalSince1970: 1_800_001_000)
    var preparationResetMoves = true
    var preparationHook: (() async -> Void)?
    var executionHook: ((String) async -> Void)?
    var verificationHook: (() async -> Void)?
    var result = CodexWeeklyTimerExecutionResult(launched: true, completed: true, updatedAuth: nil, failureDescription: nil)
    var verification: [CodexWeeklyTimerObservation?] = []
    var stampVerification = true
    var prepared: [String] = []
    var executed: [String] = []
    var executionTimes: [Date] = []
    var verificationTimes: [Date] = []
    var waits: [Duration] = []
    var reports: [String?] = []
    var finished: [String] = []
    private var freshnessCounter = 0
    private var normalReadCounter = 0

    init(seedBaseline: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = CodexWeeklyTimerAttemptStore(fileURL: directory.appendingPathComponent("attempts.json"))
        if seedBaseline { try seed(accountKey: "a") }
    }

    func cleanup() { try? FileManager.default.removeItem(at: directory) }

    func add(providerID: String, accountKey: String) throws {
        if !accounts.values.contains(accountKey) { try seed(accountKey: accountKey) }
        bindings[providerID] = UUID()
        accounts[providerID] = accountKey
    }

    func seed(accountKey: String) throws {
        _ = try store.observe(
            accountKey: accountKey, rawResetAt: start.addingTimeInterval(700),
            observedAt: start.addingTimeInterval(-1)
        )
    }

    func observation(accountKey: String = "a", used: Double = 0, reset: Date? = nil) -> CodexWeeklyTimerObservation {
        .init(accountKey: accountKey, usedPercent: used, resetsAt: reset, observedAt: nextObservedAt(), rawResetAt: reset)
    }

    func receive(_ coordinator: CodexWeeklyTimerCoordinator, providerID: String = "codex", used: Double = 0, reset: Date? = nil) {
        normalReadCounter += 1
        coordinator.receive(
            providerID: providerID, bindingID: bindings[providerID]!,
            observation: observation(
                accountKey: accounts[providerID]!, used: used,
                reset: reset ?? now.addingTimeInterval(800 + Double(normalReadCounter) * 100)
            )
        )
    }

    func coordinator() -> CodexWeeklyTimerCoordinator {
        CodexWeeklyTimerCoordinator(
            store: store,
            isCurrent: { self.enabled && self.bindings[$0] == $1 && self.accounts[$0] == $2 },
            prepare: { _, key in
                self.prepared.append(key)
                await self.preparationHook?()
                return .init(
                    observation: self.observation(
                        accountKey: key, used: self.preparationUsed,
                        reset: self.preparationReset?.addingTimeInterval(self.preparationResetMoves ? self.now.timeIntervalSince(self.start) : 0)
                    ),
                    authState: .init(auth: .init(tokens: .init(accessToken: "test")), source: .file(path: "/unused")),
                    authStore: CodexAuthStore()
                )
            },
            execute: { _, _, session in
                self.executed.append(session.observation.accountKey)
                self.executionTimes.append(self.now)
                await self.executionHook?(session.observation.accountKey)
                return self.result
            },
            verify: { _, _ in
                await self.verificationHook?()
                self.verificationTimes.append(self.now)
                guard !self.verification.isEmpty else { return nil }
                var observation = self.verification.removeFirst()
                if self.stampVerification { observation?.observedAt = self.nextObservedAt() }
                return observation
            },
            report: { _, _, message in self.reports.append(message) },
            finished: { providerID, _ in self.finished.append(providerID) },
            now: { self.now },
            wait: { duration in
                self.waits.append(duration)
                self.now = self.now.addingTimeInterval(Double(duration.components.seconds))
            }
        )
    }

    private func nextObservedAt() -> Date {
        freshnessCounter += 1
        return now.addingTimeInterval(Double(freshnessCounter) / 1_000)
    }
}

@MainActor
extension CodexWeeklyTimerRouterTests {
    @MainActor
    final class Executor: CodexWeeklyTimerExecuting {
        var startupFailureDescription: String?
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

    struct Account {
        let provider: CodexProvider
        let files: FakeFiles
        let http: TimerHTTPClient
        let path: String
        let original: String
    }

    final class TimerHTTPClient: HTTPClient, @unchecked Sendable {
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

    final class ObservationClock: @unchecked Sendable {
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
    final class Fixture {
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
            let http = clients[id] ?? TimerHTTPClient(response: .init(statusCode: 200, headers: [:], body: quota), clock: clock)
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
            let auth = CodexAuth(tokens: .init(
                accessToken: "e30.\(payload).signature", refreshToken: "refresh-\(id)",
                idToken: "e30.\(payload).signature", accountID: id
            ))
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
