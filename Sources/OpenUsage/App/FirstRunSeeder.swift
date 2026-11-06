import Foundation

/// 신규 설치의 enabled provider seeding — 첫 런치에 사용자가 실제 보유한 도구만 노출 (기존 설치 미접촉).
/// 동기로 fallback set(Claude/Codex)을 enabled-list 모드로 seed 후, 비동기 `hasLocalCredentials()` 로컬 probe
/// 결과로 교체. 미탐지 시 fallback 유지, probe 중 사용자 토글 우선.
@MainActor
enum FirstRunSeeder {
    /// 탐지 결과가 없을 때 사용하는 fallback provider set.
    static let fallbackProviderIDs: Set<String> = ["claude", "codex"]

    /// 탐지 task 반환 (테스트 await용), seeding 미발생 시 `nil`.
    /// 완료된 시딩은 반복하지 않고, 취소된 첫 탐지는 저장된 활성 목록을 유지하며 재시도.
    @discardableResult
    static func seedIfNeeded(
        isFreshInstall: Bool,
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        onboarding: OnboardingStore,
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) -> Task<Void, Never>? {
        let isRetry = enablement.isInitialDetectionPending
        guard isRetry || (isFreshInstall && enablement.enabledIDs == nil) else { return nil }

        enablement.setInitialDetectionPending(true)
        // known-provider set baseline — `NewProviderSeeder`가 이후 릴리스에 추가된 provider만 probe.
        enablement.registerKnownProviders(Set(providers.map(\.provider.id)))
        if !isRetry { onboarding.markCustomizeHintPending() }
        return seedFallbackThenDetect(
            providers: providers, enablement: enablement, logPrefix: "first run", workQueue: workQueue,
            preserveEnabledProviders: isRetry && enablement.enabledIDs != nil
        )
    }

    /// Customize "Reset All"용 온디맨드 재탐지. 의도적 사용자 reset이므로 현재 on/off 선택을 덮어씀 —
    /// fallback 동기 snap 후 탐지 set으로 교체, probe 중 사용자 토글 우선. 탐지 task 반환.
    @discardableResult
    static func reseed(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) -> Task<Void, Never> {
        seedFallbackThenDetect(providers: providers, enablement: enablement,
                               logPrefix: "reset all", probeVerb: "re-probing", workQueue: workQueue)
    }

    /// 첫 런치 seeding과 "Reset All" 공용의 seed→probe→replace 시퀀스.
    /// guard의 두 정책은 동반 필수: probe 중 사용자 토글이 탐지보다 우선, 빈 탐지는 fallback 유지.
    private static func seedFallbackThenDetect(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        logPrefix: String,
        probeVerb: String = "probing",
        workQueue: BackgroundWorkQueue,
        preserveEnabledProviders: Bool = false
    ) -> Task<Void, Never> {
        let fallback = fallbackProviderIDs.intersection(Set(providers.map(\.provider.id)))
        if !preserveEnabledProviders { enablement.seedEnabledProviders(fallback) }
        AppLog.info(.config, "\(logPrefix): enabled providers \((enablement.enabledIDs ?? []).sorted()); \(probeVerb) local credentials")
        return Task {
            let detected = await detectLocalProviders(providers, workQueue: workQueue)
            guard !Task.isCancelled else { return }
            enablement.setInitialDetectionPending(false)
            AppLog.info(.config, "\(logPrefix): detected credentials for \(detected.sorted())")
            guard enablement.enabledIDs == fallback, !detected.isEmpty else { return }
            enablement.seedEnabledProviders(detected)
        }
    }

    /// 전체 provider의 로컬 전용 credential probe — `hasLocalCredentials()`가 로그인을 보고하는 set.
    /// 첫 런치 seeding·`NewProviderSeeder`·"Reset All"이 같은 큐 사용.
    static func detectLocalProviders(
        _ providers: [ProviderRuntime], workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) async -> Set<String> {
        var detected = Set<String>()
        for provider in providers {
            guard !Task.isCancelled else { break }
            let present = await workQueue.run("credentials:\(ProviderAccountID.family(of: provider.provider.id))") {
                await provider.hasLocalCredentials()
            }
            if present == true { detected.insert(provider.provider.id) }
        }
        return detected
    }
}
