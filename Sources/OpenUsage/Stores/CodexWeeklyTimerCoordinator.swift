import Foundation

/// 0% 사용량과 이동하는 절대 리셋 시각을 확인하고 계정별 전송·검증을 직렬화.
@MainActor
final class CodexWeeklyTimerCoordinator {
    private struct Candidate {
        var providerID: String
        var bindingID: UUID
        var observation: CodexWeeklyTimerObservation
    }

    private struct PendingVerification {
        var candidate: Candidate
        var lastObservation: CodexWeeklyTimerObservation?
    }

    private let store: CodexWeeklyTimerAttemptStore
    private let isCurrent: @MainActor (String, UUID, String) -> Bool
    private let prepare: @MainActor (String, String) async throws -> CodexWeeklyTimerSession?
    private let execute: @MainActor (String, UUID, CodexWeeklyTimerSession) async -> CodexWeeklyTimerExecutionResult
    private let verify: @MainActor (String, CodexWeeklyTimerSession) async throws -> CodexWeeklyTimerObservation?
    private let report: @MainActor (String, UUID, String?) -> Void
    private let finished: @MainActor (String, UUID) -> Void
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private var pending: [Candidate] = []
    private var awaitingReset: [String: PendingVerification] = [:]
    private var accountByProvider: [String: (accountKey: String, bindingID: UUID)] = [:]
    private var active: Candidate?
    private var task: Task<Void, Never>?
    private var stopped = false

    init(
        store: CodexWeeklyTimerAttemptStore = CodexWeeklyTimerAttemptStore(),
        isCurrent: @escaping @MainActor (String, UUID, String) -> Bool,
        prepare: @escaping @MainActor (String, String) async throws -> CodexWeeklyTimerSession?,
        execute: @escaping @MainActor (String, UUID, CodexWeeklyTimerSession) async -> CodexWeeklyTimerExecutionResult,
        verify: @escaping @MainActor (String, CodexWeeklyTimerSession) async throws -> CodexWeeklyTimerObservation?,
        report: @escaping @MainActor (String, UUID, String?) -> Void,
        finished: @escaping @MainActor (String, UUID) -> Void = { _, _ in },
        now: @escaping @MainActor () -> Date = Date.init,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.isCurrent = isCurrent
        self.prepare = prepare
        self.execute = execute
        self.verify = verify
        self.report = report
        self.finished = finished
        self.now = now
        self.wait = wait
    }

    deinit { task?.cancel() }

    var hasPendingWork: Bool {
        task != nil || active != nil || !pending.isEmpty
    }

    func isRunning(providerID: String) -> Bool {
        guard let active else { return false }
        return active.providerID == providerID
            || accountByProvider[providerID]?.accountKey == active.observation.accountKey
    }

    func isRunning(providerID: String, bindingID: UUID) -> Bool {
        guard let active else { return false }
        if active.providerID == providerID { return active.bindingID == bindingID }
        guard let binding = accountByProvider[providerID], binding.bindingID == bindingID else { return false }
        return binding.accountKey == active.observation.accountKey
    }

    func receive(providerID: String, bindingID: UUID, observation: CodexWeeklyTimerObservation) {
        guard !stopped, isCurrent(providerID, bindingID, observation.accountKey) else { return }
        accountByProvider[providerID] = (observation.accountKey, bindingID)
        let candidate = Candidate(providerID: providerID, bindingID: bindingID, observation: observation)
        do {
            let change = try store.observe(
                accountKey: observation.accountKey, rawResetAt: observation.rawResetAt,
                observedAt: observation.observedAt, usedPercent: observation.usedPercent
            )
            guard change != .stale else { return }
            if change != .incomparable || observation.rawResetAt == nil || observation.usedPercent != 0 {
                pending.removeAll { $0.providerID == providerID }
            }
            recoverVerification(observation, change: change)
            guard active?.observation.accountKey != observation.accountKey,
                  change == .changed, observation.usedPercent == 0,
                  try store.attempt(for: observation.accountKey).map({ $0.notBefore <= now() }) ?? true
            else { return }
        } catch {
            fail(candidate, "Weekly timer automation could not read its saved state. No message was sent.")
            return
        }
        pending.append(candidate)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    func invalidate(providerID: String) {
        pending.removeAll { $0.providerID == providerID }
        accountByProvider[providerID] = nil
    }

    func stop() {
        stopped = true
        pending.removeAll()
        task?.cancel()
    }

    func shutdown() async {
        let runningTask = task
        stop()
        await runningTask?.value
    }

    private func drain() async {
        while !pending.isEmpty, !Task.isCancelled, !stopped {
            let candidate = pending.removeFirst()
            guard current(candidate) else { continue }
            active = candidate
            await process(candidate)
            active = nil
            if !stopped { finished(candidate.providerID, candidate.bindingID) }
        }
        task = nil
    }

    private func process(_ candidate: Candidate) async {
        let accountKey = candidate.observation.accountKey
        do {
            guard try store.isLatest(candidate.observation) else { return }
            if let existing = try store.attempt(for: accountKey), existing.notBefore > now() { return }
        } catch {
            fail(candidate, "Weekly timer automation could not read its saved state. No message was sent.")
            return
        }

        let session: CodexWeeklyTimerSession
        do {
            guard let prepared = try await prepare(candidate.providerID, accountKey), current(candidate),
                  prepared.observation.accountKey == accountKey
            else { return }
            session = prepared
        } catch is CancellationError {
            return
        } catch {
            fail(candidate, "Weekly timer message could not be prepared. Refresh to try again.")
            return
        }

        var attempt: CodexWeeklyTimerAttempt
        do {
            guard try store.isLatest(candidate.observation) else { return }
            let change = try store.observe(
                accountKey: accountKey, rawResetAt: session.observation.rawResetAt,
                observedAt: session.observation.observedAt, usedPercent: session.observation.usedPercent
            )
            guard change != .stale, session.observation.usedPercent == 0,
                  let reset = session.observation.rawResetAt,
                  !(change == .unchanged && reset > now()),
                  let observedAt = try store.latestObservationAt(accountKey: accountKey)
            else { return }
            guard current(candidate), let reserved = try store.begin(
                accountKey: accountKey, resetBefore: reset, now: now(), expectedObservedAt: observedAt
            ) else { return }
            attempt = reserved
            awaitingReset[accountKey] = nil
        } catch {
            fail(candidate, "Weekly timer automation could not save its state. No message was sent.")
            return
        }

        // await 없는 예약→실행 경계. 프로세스 시작 뒤 불명확한 종료도 예약을 유지.
        let result = await execute(candidate.providerID, candidate.bindingID, session)
        attempt.execution = result.completed ? .completed : .failed
        var stateSaveFailed = false
        do { try store.update(accountKey: accountKey, attempt: attempt) }
        catch {
            stateSaveFailed = true
            fail(candidate, "Weekly timer automation could not update its saved state.")
        }
        guard current(candidate) else { return }
        guard result.launched else {
            fail(candidate, result.failureDescription ?? "Weekly timer message could not be started. Automatic retries wait five minutes.")
            return
        }
        var lastPostObservation: CodexWeeklyTimerObservation?
        let verified = await verifyTimer(
            candidate, session: session, attempt: &attempt, lastObservation: &lastPostObservation
        )
        guard current(candidate) else { return }
        if let failure = result.failureDescription {
            fail(candidate, failure)
        } else if !result.completed {
            fail(candidate, "Weekly timer message completion could not be confirmed. Automatic retries wait five minutes.")
        } else if stateSaveFailed {
            fail(candidate, "Weekly timer automation could not update its saved state.")
        } else if !verified {
            fail(candidate, "Weekly timer message completed, but the server reset time could not be confirmed.")
            awaitingReset[accountKey] = PendingVerification(candidate: candidate, lastObservation: lastPostObservation)
        } else {
            report(candidate.providerID, candidate.bindingID, nil)
        }
    }

    private func verifyTimer(
        _ candidate: Candidate, session: CodexWeeklyTimerSession, attempt: inout CodexWeeklyTimerAttempt,
        lastObservation: inout CodexWeeklyTimerObservation?
    ) async -> Bool {
        let endedAt = now()
        var previousReset: Date?
        var previousObservedAt: Date?
        let interval = CodexWeeklyTimerObservation.resetTimeTolerance + 5
        for delay: TimeInterval in [0, interval, interval * 2] {
            guard current(candidate) else { return false }
            let remaining = endedAt.addingTimeInterval(delay).timeIntervalSince(now())
            if remaining > 0 {
                do { try await wait(.seconds(remaining)) } catch { return false }
                guard current(candidate) else { return false }
            }
            do {
                guard let observation = try await verify(candidate.providerID, session), current(candidate),
                      observation.accountKey == candidate.observation.accountKey,
                      observation.observedAt >= endedAt
                else { previousReset = nil; continue }
                let change = try store.observe(
                    accountKey: observation.accountKey, rawResetAt: observation.rawResetAt,
                    observedAt: observation.observedAt, usedPercent: observation.usedPercent
                )
                guard change != .stale else { previousReset = nil; continue }
                attempt.lastVerifiedAt = observation.observedAt
                attempt.resetAfter = observation.rawResetAt
                try store.update(accountKey: observation.accountKey, attempt: attempt)
                guard let reset = observation.rawResetAt, reset > now() else {
                    previousReset = nil
                    lastObservation = nil
                    continue
                }
                lastObservation = observation
                if CodexWeeklyTimerObservation.resetTimesMatch(previousReset, reset), change == .unchanged,
                   let previousObservedAt,
                   observation.observedAt.timeIntervalSince(previousObservedAt) > CodexWeeklyTimerObservation.resetTimeTolerance {
                    return true
                }
                if !CodexWeeklyTimerObservation.resetTimesMatch(previousReset, reset) {
                    previousReset = reset
                    previousObservedAt = observation.observedAt
                }
            } catch is CancellationError {
                return false
            } catch {
                previousReset = nil
                AppLog.error(LogTag.plugin(candidate.providerID), "Weekly timer reset verification failed")
            }
        }
        return false
    }

    private func recoverVerification(
        _ observation: CodexWeeklyTimerObservation, change: CodexWeeklyTimerObservationChange
    ) {
        guard var waiting = awaitingReset[observation.accountKey] else { return }
        guard let reset = observation.rawResetAt, reset > now() else {
            waiting.lastObservation = nil
            awaitingReset[observation.accountKey] = waiting
            return
        }
        if change == .unchanged,
           let previous = waiting.lastObservation,
           CodexWeeklyTimerObservation.resetTimesMatch(previous.rawResetAt, reset),
           observation.observedAt.timeIntervalSince(previous.observedAt) > CodexWeeklyTimerObservation.resetTimeTolerance {
            awaitingReset[observation.accountKey] = nil
            if current(waiting.candidate) { report(waiting.candidate.providerID, waiting.candidate.bindingID, nil) }
        } else if !CodexWeeklyTimerObservation.resetTimesMatch(waiting.lastObservation?.rawResetAt, reset) {
            waiting.lastObservation = observation
            awaitingReset[observation.accountKey] = waiting
        }
    }

    private func current(_ candidate: Candidate) -> Bool {
        !stopped && !Task.isCancelled
            && isCurrent(candidate.providerID, candidate.bindingID, candidate.observation.accountKey)
    }

    private func fail(_ candidate: Candidate, _ message: String) {
        awaitingReset[candidate.observation.accountKey] = nil
        AppLog.error(LogTag.plugin(candidate.providerID), message)
        guard current(candidate) else { return }
        report(candidate.providerID, candidate.bindingID, message)
    }
}
