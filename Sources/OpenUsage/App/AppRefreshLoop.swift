import Foundation

/// usage·공개 상태의 주기 갱신 소유자 — enablement wake와 종료 취소를 같은 루프에서 처리.
@MainActor
enum AppRefreshLoop {
    static func start(
        dataStore: WidgetDataStore,
        providerStatus: ProviderStatusStore,
        telemetry: TelemetryRecorder,
        enabledProviderIDs: @escaping @MainActor () -> [String],
        reconcileAccounts: @escaping @MainActor () async -> Void,
        wakeSignal: RefreshWakeSignal = RefreshWakeSignal(),
        interval: TimeInterval = RefreshSetting.interval
    ) -> Task<Void, Never> {
        Task {
            let heartbeat = Task { await telemetry.runHeartbeat() }
            defer { heartbeat.cancel() }
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    telemetry.tick()
                    await reconcileAccounts()
                    guard !Task.isCancelled else { return }
                    let statusProviderIDs = enabledProviderIDs()
                    async let statusRefresh: Void = providerStatus.refresh(providerIDs: statusProviderIDs)
                    await dataStore.refreshAll()
                    // fetch 없는 순회에서도 시간 경과에 따른 알림·일자 전환 재평가.
                    await dataStore.evaluateNotifications()
                    // usage 완료부터 heartbeat 대기 — status 지연을 다음 갱신 주기에 더하지 않음.
                    async let nextWake: Void = wakeSignal.waitForWake(timeout: interval)
                    _ = await (statusRefresh, nextWake)
                }
            } onCancel: {
                heartbeat.cancel()
                Task { @MainActor in providerStatus.cancelRefreshes() }
            }
        }
    }
}
