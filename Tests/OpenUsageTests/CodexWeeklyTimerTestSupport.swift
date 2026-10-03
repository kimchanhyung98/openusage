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
    var preparationReset: Date? = Date(timeIntervalSince1970: 1_800_000_850)
    var preparationHook: (() async -> Void)?
    var executionHook: ((String) async -> Void)?
    var verificationHook: (() async -> Void)?
    var result = CodexWeeklyTimerExecutionResult(launched: true, completed: true, updatedAuth: nil, failureDescription: nil)
    var verification: [CodexWeeklyTimerObservation?] = []
    var stampVerification = true
    var prepared: [String] = []
    var executed: [String] = []
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
                reset: reset ?? start.addingTimeInterval(800 + Double(normalReadCounter) * 100)
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
                    observation: self.observation(accountKey: key, used: self.preparationUsed, reset: self.preparationReset),
                    authState: .init(auth: .init(tokens: .init(accessToken: "test")), source: .file(path: "/unused")),
                    authStore: CodexAuthStore()
                )
            },
            execute: { _, _, session in
                self.executed.append(session.observation.accountKey)
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
