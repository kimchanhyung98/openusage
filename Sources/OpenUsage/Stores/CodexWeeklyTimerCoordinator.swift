import Foundation

/// 0% 사용량과 이동하는 절대 리셋 시각을 확인하고 계정별 전송·검증을 직렬화.
@MainActor
final class CodexWeeklyTimerCoordinator {
    private struct Candidate {
        var providerID: String
        var bindingID: UUID
        var observation: CodexWeeklyTimerObservation
        var observationEpoch: UUID
    }

    private struct PendingVerification {
        var lastObservation: CodexWeeklyTimerObservation?
    }

    private let store: CodexWeeklyTimerAttemptStore
    private let isCurrent: @MainActor (String, UUID, String) -> Bool
    private let prepare: @MainActor (String, String) async throws -> CodexWeeklyTimerSession?
    private let execute: @MainActor (String, UUID, CodexWeeklyTimerSession, @escaping @MainActor () -> Bool) async -> CodexWeeklyTimerExecutionResult
    private let verify: @MainActor (String, CodexWeeklyTimerSession) async throws -> CodexWeeklyTimerObservation?
    private let report: @MainActor (String, UUID, String?) -> Void
    private let finished: @MainActor (String, UUID) -> Void
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private var pending: [Candidate] = []
    private var awaitingReset: [String: PendingVerification] = [:]
    private var preparationRetries: Set<String> = []
    private var reportedSendLimits: [String: Date] = [:]
    private var accountByProvider: [String: (accountKey: String, bindingID: UUID)] = [:]
    private var active: Candidate?
    private var executing: Candidate?
    private var task: Task<Void, Never>?
    private var observationEpoch = UUID()
    private var stopped = false

    init(
        store: CodexWeeklyTimerAttemptStore = CodexWeeklyTimerAttemptStore(),
        isCurrent: @escaping @MainActor (String, UUID, String) -> Bool,
        prepare: @escaping @MainActor (String, String) async throws -> CodexWeeklyTimerSession?,
        execute: @escaping @MainActor (String, UUID, CodexWeeklyTimerSession, @escaping @MainActor () -> Bool) async -> CodexWeeklyTimerExecutionResult,
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
        guard let active = executing else { return false }
        return active.providerID == providerID
            || accountByProvider[providerID]?.accountKey == active.observation.accountKey
    }

    func receive(
        providerID: String, bindingID: UUID, observation: CodexWeeklyTimerObservation,
        checkUnconfirmedReset: Bool = false
    ) {
        guard !stopped, isCurrent(providerID, bindingID, observation.accountKey) else { return }
        accountByProvider[providerID] = (observation.accountKey, bindingID)
        let candidate = Candidate(providerID: providerID, bindingID: bindingID, observation: observation,
                                  observationEpoch: observationEpoch)
        do {
            let change = try store.observe(
                accountKey: observation.accountKey, rawResetAt: observation.rawResetAt,
                observedAt: observation.observedAt, usedPercent: observation.usedPercent
            )
            guard change != .stale else { return }
            if change != .incomparable || observation.rawResetAt == nil || observation.usedPercent != 0 {
                pending.removeAll { $0.observation.accountKey == observation.accountKey }
            }
            recoverVerification(candidate, change: change)
            if change == .unchanged || observation.usedPercent > 0,
               preparationRetries.remove(observation.accountKey) != nil {
                report(candidate.providerID, candidate.bindingID, nil)
            }
            guard change != .unchanged,
                  change == .changed || checkUnconfirmedReset || preparationRetries.contains(observation.accountKey),
                  observation.usedPercent == 0,
                  let reset = observation.rawResetAt, reset > now(),
                  try canPrepare(candidate, reportLimit: change == .changed)
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

    func invalidateObservations() {
        observationEpoch = UUID()
        pending.removeAll()
        awaitingReset = awaitingReset.mapValues { _ in PendingVerification(lastObservation: nil) }
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
            guard try isLatest(candidate) else { return }
            guard try canPrepare(candidate) else { return }
        } catch {
            fail(candidate, "Weekly timer automation could not read its saved state. No message was sent.")
            return
        }

        var session: CodexWeeklyTimerSession
        do {
            guard let prepared = try await prepare(candidate.providerID, accountKey), current(candidate),
                  prepared.observation.accountKey == accountKey
            else { return }
            session = prepared
            if preparationRetries.remove(accountKey) != nil {
                report(candidate.providerID, candidate.bindingID, nil)
            }
        } catch is CancellationError {
            return
        } catch {
            fail(candidate, "Weekly timer message could not be prepared. Refresh to try again.")
            preparationRetries.insert(accountKey)
            return
        }

        let firstObservation = session.observation
        let preparationObservedAt: Date
        let revalidationState: CodexWeeklyTimerAttemptStore.RevalidationState
        do {
            guard try isLatest(candidate) else { return }
            let change = try store.observe(
                accountKey: accountKey, rawResetAt: session.observation.rawResetAt,
                observedAt: session.observation.observedAt, usedPercent: session.observation.usedPercent
            )
            guard change != .stale, session.observation.usedPercent == 0,
                  let reset = session.observation.rawResetAt, reset > now(),
                  change != .unchanged,
                  let observedAt = try store.latestObservationAt(accountKey: accountKey),
                  let state = try store.revalidationState(accountKey: accountKey, now: now()),
                  !CodexWeeklyTimerObservation.resetTimesMatch(reset, state.confirmedReset)
            else { return }
            preparationObservedAt = observedAt
            revalidationState = state
        } catch {
            fail(candidate, "Weekly timer automation could not save its state. No message was sent.")
            return
        }

        do {
            // 다른 클라이언트가 이미 시작한 타이머와 단발성 시각 변화를 전송 전에 구분.
            try await wait(.seconds(CodexWeeklyTimerObservation.verificationInterval))
            guard current(candidate),
                  try store.latestObservationAt(accountKey: accountKey) == preparationObservedAt,
                  let prepared = try await prepare(candidate.providerID, accountKey), current(candidate),
                  prepared.observation.accountKey == accountKey else { return }
            session = prepared
        } catch is CancellationError {
            return
        } catch {
            fail(candidate, "Weekly timer message could not be prepared. Refresh to try again.")
            preparationRetries.insert(accountKey)
            return
        }

        var attempt: CodexWeeklyTimerAttempt
        do {
            guard try store.latestObservationAt(accountKey: accountKey) == preparationObservedAt else { return }
            guard current(candidate) else { return }
            guard let reserved = try store.beginAfterRevalidation(
                first: firstObservation, second: session.observation, expectedState: revalidationState, now: now()
            ) else {
                _ = try store.observe(accountKey: accountKey, rawResetAt: session.observation.rawResetAt,
                                      observedAt: session.observation.observedAt,
                                      usedPercent: session.observation.usedPercent)
                return
            }
            attempt = reserved
            awaitingReset[accountKey] = nil
        } catch {
            fail(candidate, "Weekly timer automation could not save its state. No message was sent.")
            return
        }

        // await 없는 예약→실행 경계. 프로세스 시작 뒤 불명확한 종료도 예약을 유지.
        executing = candidate
        let result = await execute(candidate.providerID, candidate.bindingID, session) { [weak self] in
            self?.current(candidate) == true
        }
        executing = nil
        attempt.execution = result.completed ? .completed : .failed
        var stateSaveFailed = false
        do { try store.update(accountKey: accountKey, attempt: attempt) }
        catch {
            stateSaveFailed = true
            fail(candidate, "Weekly timer automation could not update its saved state.")
        }
        guard current(candidate) else { return }
        guard result.launched else {
            fail(candidate, result.failureDescription ?? "Weekly timer message could not be started. Retries wait at least five minutes and are limited to 2 attempts per 24 hours.")
            return
        }
        var lastPostObservation: CodexWeeklyTimerObservation?
        let verified = await verifyTimer(
            candidate, session: session, attempt: &attempt, lastObservation: &lastPostObservation
        )
        guard current(candidate) else { return }
        if let failure = result.failureDescription { AppLog.error(LogTag.plugin(candidate.providerID), failure) }
        if stateSaveFailed {
            fail(candidate, "Weekly timer automation could not update its saved state.")
        } else if !result.verificationCanClearFailure {
            fail(candidate, result.failureDescription ?? "Weekly timer credentials could not be updated.")
        } else if !verified {
            fail(candidate, result.failureDescription ?? (result.completed
                ? "Weekly timer message completed, but the server reset time could not be confirmed."
                : "Weekly timer message completion could not be confirmed. Retries wait at least five minutes and are limited to 2 attempts per 24 hours."))
            awaitingReset[accountKey] = PendingVerification(lastObservation: lastPostObservation)
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
        let interval = CodexWeeklyTimerObservation.verificationInterval
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
                   observation.observedAt.timeIntervalSince(previousObservedAt) >= CodexWeeklyTimerObservation.verificationInterval {
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
        _ candidate: Candidate, change: CodexWeeklyTimerObservationChange
    ) {
        let observation = candidate.observation
        guard var waiting = awaitingReset[observation.accountKey] else { return }
        guard let reset = observation.rawResetAt, reset > now() else {
            waiting.lastObservation = nil
            awaitingReset[observation.accountKey] = waiting
            return
        }
        if change == .unchanged,
           let previous = waiting.lastObservation,
           CodexWeeklyTimerObservation.resetTimesMatch(previous.rawResetAt, reset),
           observation.observedAt.timeIntervalSince(previous.observedAt) >= CodexWeeklyTimerObservation.verificationInterval {
            awaitingReset[observation.accountKey] = nil
            reportedSendLimits[observation.accountKey] = nil
            if current(candidate) { report(candidate.providerID, candidate.bindingID, nil) }
        } else if !CodexWeeklyTimerObservation.resetTimesMatch(waiting.lastObservation?.rawResetAt, reset) {
            waiting.lastObservation = observation
            awaitingReset[observation.accountKey] = waiting
        }
    }

    private func current(_ candidate: Candidate) -> Bool {
        !stopped && !Task.isCancelled
            && candidate.observationEpoch == observationEpoch
            && isCurrent(candidate.providerID, candidate.bindingID, candidate.observation.accountKey)
    }

    private func canPrepare(_ candidate: Candidate, reportLimit: Bool = true) throws -> Bool {
        let accountKey = candidate.observation.accountKey
        if let until = try store.sendLimitResetsAt(accountKey: accountKey, now: now()) {
            if reportLimit, reportedSendLimits[accountKey] != until {
                fail(candidate, "Weekly timer messages paused: this account reached the limit of 2 attempts in 24 hours. Usage checks will continue.")
                reportedSendLimits[accountKey] = until
                awaitingReset[accountKey] = PendingVerification(lastObservation: candidate.observation)
            }
            return false
        }
        if reportedSendLimits.removeValue(forKey: accountKey) != nil {
            awaitingReset[accountKey] = nil
            report(candidate.providerID, candidate.bindingID, nil)
        }
        guard let state = try store.revalidationState(accountKey: accountKey, now: now()) else { return false }
        return !CodexWeeklyTimerObservation.resetTimesMatch(candidate.observation.rawResetAt, state.confirmedReset)
    }

    private func isLatest(_ candidate: Candidate) throws -> Bool {
        try store.isLatest(candidate.observation) || store.isLatestReceived(candidate.observation)
    }

    private func fail(_ candidate: Candidate, _ message: String) {
        awaitingReset[candidate.observation.accountKey] = nil
        AppLog.error(LogTag.plugin(candidate.providerID), message)
        guard current(candidate) else { return }
        report(candidate.providerID, candidate.bindingID, message)
    }
}
