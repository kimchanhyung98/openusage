import Foundation

/// 신규 설치의 enabled provider seeding — 첫 런치에 사용자가 실제 보유한 도구만 노출 (기존 설치 미접촉).
/// 동기로 fallback set(Claude/Codex/Kimi)을 enabled-list 모드로 seed 후, 비동기 `hasLocalCredentials()` 로컬 probe
/// 결과로 교체. 미탐지 시 fallback 유지, probe 중 사용자 토글 우선.
@MainActor
enum FirstRunSeeder {
    /// 탐지 결과가 없을 때 사용하는 fallback provider set.
    static let fallbackProviderIDs: Set<String> = ["claude", "codex", "kimi"]

    /// 탐지 task 반환 (테스트 await용), seeding 미발생 시 `nil`.
    /// `enabledIDs == nil` guard로 멱등 — 이미 seed된 store 미덮어쓰기.
    @discardableResult
    static func seedIfNeeded(
        isFreshInstall: Bool,
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        onboarding: OnboardingStore
    ) -> Task<Void, Never>? {
        guard isFreshInstall, enablement.enabledIDs == nil else { return nil }

        // known-provider set baseline — `NewProviderSeeder`가 이후 릴리스에 추가된 provider만 probe.
        enablement.registerKnownProviders(Set(providers.map(\.provider.id)))
        onboarding.markCustomizeHintPending()
        return seedFallbackThenDetect(providers: providers, enablement: enablement, logPrefix: "first run")
    }

    /// Customize "Reset All"용 온디맨드 재탐지. 의도적 사용자 reset이므로 현재 on/off 선택을 덮어씀 —
    /// fallback 동기 snap 후 탐지 set으로 교체, probe 중 사용자 토글 우선. 탐지 task 반환.
    @discardableResult
    static func reseed(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never> {
        seedFallbackThenDetect(providers: providers, enablement: enablement,
                               logPrefix: "reset all", probeVerb: "re-probing")
    }

    /// 첫 런치 seeding과 "Reset All" 공용의 seed→probe→replace 시퀀스.
    /// guard의 두 정책은 동반 필수: probe 중 사용자 토글이 탐지보다 우선, 빈 탐지는 fallback 유지.
    private static func seedFallbackThenDetect(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        logPrefix: String,
        probeVerb: String = "probing"
    ) -> Task<Void, Never> {
        let fallback = fallbackProviderIDs.intersection(Set(providers.map(\.provider.id)))
        enablement.seedEnabledProviders(fallback)
        AppLog.info(.config, "\(logPrefix): seeded providers \(fallback.sorted()); \(probeVerb) local credentials")
        return Task {
            let detected = await detectLocalProviders(providers)
            AppLog.info(.config, "\(logPrefix): detected credentials for \(detected.sorted())")
            guard enablement.enabledIDs == fallback, !detected.isEmpty else { return }
            enablement.seedEnabledProviders(detected)
        }
    }

    /// 전체 provider의 로컬 전용 credential probe — `hasLocalCredentials()`가 로그인을 보고하는 set.
    /// 첫 런치 seeding·`NewProviderSeeder`·"Reset All" 공용. probe는 동시 실행 필수 —
    /// 순차 실행 시 `security`/`sqlite3` 대기(~5s)가 합산되어 탐지 지연.
    static func detectLocalProviders(_ providers: [ProviderRuntime]) async -> Set<String> {
        let probes = providers.map { provider in
            (provider.provider.id, Task { await provider.hasLocalCredentials() })
        }
        var detected = Set<String>()
        for (id, probe) in probes where await probe.value {
            detected.insert(id)
        }
        return detected
    }
}
