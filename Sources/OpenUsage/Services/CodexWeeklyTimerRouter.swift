import Foundation

/// 활성 계정의 최신 조회만 자동 전송에 연결하고 계정 교체 뒤의 결과 게시 차단.
@MainActor
final class CodexWeeklyTimerRouter {
    private struct Binding {
        let id = UUID()
        var provider: CodexProvider
        var accountKey: String?
    }

    private var bindings: [String: Binding]
    private var identityKeys: [String: String]
    private let isProviderEnabled: (String) -> Bool
    private let executor: any CodexWeeklyTimerExecuting
    private let store: CodexWeeklyTimerAttemptStore
    private var isShuttingDown = false
    private let report: (String, String?) -> Void
    private let refresh: @MainActor (String, @escaping @MainActor () -> Bool) async -> Void
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private lazy var coordinator = CodexWeeklyTimerCoordinator(
        store: store,
        isCurrent: { [weak self] in self?.isCurrent($0, bindingID: $1, accountKey: $2) == true },
        prepare: { [weak self] providerID, accountKey in
            guard let provider = self?.bindings[providerID]?.provider else { return nil }
            return try await provider.prepareWeeklyTimerSession(expectedAccountKey: accountKey)
        },
        execute: { [weak self] providerID, bindingID, session in
            guard let self, let binding = self.bindings[providerID], binding.id == bindingID else {
                return CodexWeeklyTimerExecutionResult(
                    launched: false, completed: false, updatedAuth: nil,
                    failureDescription: "Weekly timer account changed before the message was sent."
                )
            }
            var result = await self.executor.execute(auth: session.authState.auth) { [weak self] in
                guard self?.isCurrent(providerID, bindingID: bindingID, accountKey: session.observation.accountKey) == true else {
                    return false
                }
                do {
                    try await binding.provider.validateWeeklyTimerSession(session)
                } catch {
                    AppDiagnostics.record(.weeklyTimer, result: .failure, providerID: providerID, error: error,
                                          localContext: "Timer authentication changed before launch")
                    return false
                }
                return self?.isCurrent(providerID, bindingID: bindingID, accountKey: session.observation.accountKey) == true
            }
            if let updatedAuth = result.updatedAuth {
                do {
                    // 종료 취소 뒤에도 CLI가 회전한 토큰 반영 완료까지 대기.
                    let save = Task {
                        try await binding.provider.persistUpdatedWeeklyTimerAuth(updatedAuth, original: session.authState)
                    }
                    try await save.value
                } catch {
                    AppDiagnostics.record(.weeklyTimer, result: .failure, providerID: providerID, error: error,
                                          localContext: "Could not persist timer credentials")
                    result.failureDescription = "Weekly timer credentials changed. Refresh this account before trying again."
                    result.verificationCanClearFailure = false
                }
            }
            return result
        },
        verify: { [weak self] providerID, session in
            guard let provider = self?.bindings[providerID]?.provider else { return nil }
            return try await provider.verifyWeeklyTimer(expectedAccountKey: session.observation.accountKey)
        },
        report: { [weak self] providerID, bindingID, message in
            guard let self, self.bindings[providerID]?.id == bindingID else { return }
            self.report(providerID, message)
            AppDiagnostics.record(.weeklyTimer, result: message == nil ? .success : .failure,
                                  providerID: providerID)
        },
        finished: { [weak self] providerID, _ in
            guard let self, !self.isShuttingDown, let currentBindingID = self.bindings[providerID]?.id else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.refresh(providerID) { [weak self] in
                    self?.isShuttingDown == false && self?.bindings[providerID]?.id == currentBindingID
                        && self?.isProviderEnabled(providerID) == true
                }
            }
        },
        now: now,
        wait: wait
    )

    init(
        providers: [CodexProvider],
        identityKeys: [String: String] = [:],
        isProviderEnabled: @escaping (String) -> Bool,
        executor: any CodexWeeklyTimerExecuting = CodexWeeklyTimerExecutor(),
        store: CodexWeeklyTimerAttemptStore = CodexWeeklyTimerAttemptStore(),
        report: @escaping (String, String?) -> Void,
        refresh: @escaping @MainActor (String, @escaping @MainActor () -> Bool) async -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.bindings = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, Binding(provider: $0)) })
        self.identityKeys = identityKeys
        self.isProviderEnabled = isProviderEnabled
        self.executor = executor
        self.store = store
        self.report = report
        self.refresh = refresh
        self.now = now
        self.wait = wait
    }

    func receive(_ snapshot: ProviderSnapshot, trigger: RefreshTrigger) {
        guard !isShuttingDown, trigger != .cli, trigger != .weeklyTimer,
              var binding = bindings[snapshot.providerID],
              let observedAt = snapshot.liveQuotaObservedAt,
              let observation = binding.provider.weeklyTimerObservation,
              observation.observedAt == observedAt else { return }
        if let accountKey = binding.accountKey, accountKey != observation.accountKey {
            coordinator.invalidate(providerID: snapshot.providerID)
            binding = Binding(provider: binding.provider)
            report(snapshot.providerID, nil)
        }
        binding.accountKey = observation.accountKey
        bindings[snapshot.providerID] = binding
        coordinator.receive(providerID: snapshot.providerID, bindingID: binding.id, observation: observation)
    }

    func isRunning(providerID: String) -> Bool {
        coordinator.isRunning(providerID: providerID)
    }

    var hasPendingWork: Bool { coordinator.hasPendingWork }

    func shutdown() async {
        isShuttingDown = true
        await coordinator.shutdown()
    }

    func invalidate(providerIDs: Set<String>? = nil) {
        let affected = providerIDs ?? Set(bindings.keys.filter { !isProviderEnabled($0) })
        for providerID in affected {
            guard let binding = bindings[providerID] else { continue }
            coordinator.invalidate(providerID: providerID)
            bindings[providerID] = Binding(provider: binding.provider)
            report(providerID, nil)
        }
    }

    func reconfigure(providers: [CodexProvider], identityKeys: [String: String] = [:]) {
        let removed = Set(bindings.keys).subtracting(providers.map { $0.provider.id })
        invalidate(providerIDs: removed)
        for providerID in removed { bindings[providerID] = nil }
        for provider in providers {
            let providerID = provider.provider.id
            if var binding = bindings[providerID],
               binding.provider === provider || (identityKeys[providerID] != nil && self.identityKeys[providerID] == identityKeys[providerID]) {
                binding.provider = provider
                bindings[providerID] = binding
            } else {
                invalidate(providerIDs: [providerID])
                bindings[providerID] = Binding(provider: provider)
            }
        }
        self.identityKeys = identityKeys
    }

    private func isCurrent(_ providerID: String, bindingID: UUID, accountKey: String) -> Bool {
        guard !isShuttingDown, isProviderEnabled(providerID), let binding = bindings[providerID], binding.id == bindingID else { return false }
        return binding.accountKey == accountKey
    }
}
