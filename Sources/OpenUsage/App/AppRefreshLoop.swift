import Foundation

/// 일반 5분·Claude 15분 갱신 소유자. 최초 계정 재조정 뒤 두 작업을 독립 실행.
@MainActor
enum AppRefreshLoop {
    @MainActor private final class ClaudeTaskOwner {
        var task: Task<Void, Never>?
    }

    static func start(
        dataStore: WidgetDataStore,
        providerStatus: ProviderStatusStore,
        telemetry: TelemetryRecorder,
        enabledProviderIDs: @escaping @MainActor () -> [String],
        reconcileAccounts: @escaping @MainActor () async -> Void,
        wakeSignal: RefreshWakeSignal = RefreshWakeSignal(),
        interval: TimeInterval = RefreshSetting.interval,
        claudeWakeSignal: RefreshWakeSignal = RefreshWakeSignal(),
        now: @escaping @MainActor () -> Date = Date.init
    ) -> Task<Void, Never> {
        Task {
            let heartbeat = Task { await telemetry.runHeartbeat() }
            let claudeTask = ClaudeTaskOwner()
            var nextGeneralPassAt = now()
            defer { heartbeat.cancel(); claudeTask.task?.cancel() }
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    telemetry.tick()
                    await reconcileAccounts()
                    guard !Task.isCancelled else { return }
                    if claudeTask.task == nil {
                        claudeTask.task = Task {
                            while !Task.isCancelled {
                                await dataStore.refreshAll(cadence: .claude)
                                guard !Task.isCancelled else { return }
                                await dataStore.evaluateNotifications()
                                let deadline = dataStore.nextScheduledRefresh(for: .claude, at: now())
                                    ?? now().addingTimeInterval(RefreshSetting.slowInterval)
                                await claudeWakeSignal.waitForWake(timeout: max(1, deadline.timeIntervalSince(now())))
                            }
                        }
                    }
                    let statusProviderIDs = enabledProviderIDs()
                    async let statusRefresh: Void = providerStatus.refresh(providerIDs: statusProviderIDs)
                    await dataStore.refreshAll(cadence: .regular)
                    guard !Task.isCancelled else { return }
                    // fetch 없는 순회에서도 시간 경과에 따른 알림·일자 전환 재평가.
                    await dataStore.evaluateNotifications()
                    guard !Task.isCancelled else { return }
                    // usage 완료부터 heartbeat 대기 — status 지연을 다음 갱신 주기에 더하지 않음.
                    if nextGeneralPassAt <= now() { nextGeneralPassAt = now().addingTimeInterval(interval) }
                    let deadline = dataStore.nextScheduledRefresh(for: .regular, at: now())
                        ?? nextGeneralPassAt
                    dataStore.nextGeneralRefreshAt = min(deadline, nextGeneralPassAt)
                    let delay = max(0.001, min(deadline, nextGeneralPassAt).timeIntervalSince(now()))
                    async let nextWake: Void = wakeSignal.waitForWake(timeout: delay)
                    _ = await (statusRefresh, nextWake)
                }
            } onCancel: {
                heartbeat.cancel()
                Task { @MainActor in
                    claudeTask.task?.cancel()
                    providerStatus.cancelRefreshes()
                }
            }
            claudeTask.task?.cancel()
            await claudeTask.task?.value
        }
    }
}
