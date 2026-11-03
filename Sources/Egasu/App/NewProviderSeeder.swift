import Foundation

/// 업데이트로 추가된 provider의 자동 활성화 — 사용자가 실제 보유한 도구만.
/// registry와 known-provider set의 diff 대상만 로컬 probe — 이미 본 provider 미접촉, 사용자의 off 선택 보존.
/// one-shot: 새 ID는 probe 전 동기로 known 처리, credential 없는 provider는 재probe 없음.
@MainActor
enum NewProviderSeeder {
    /// 탐지 task 반환 (테스트 await용); 할 일 없으면 `nil` — 새 provider 없음 또는 legacy disabled-list 모드.
    @discardableResult
    static func reconcileIfNeeded(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore
    ) -> Task<Void, Never>? {
        guard enablement.enabledIDs != nil else { return nil }

        let currentIDs = Set(providers.map(\.provider.id))
        // known set 없는 enabled-list store는 tracking 이전 seed — "new"와 "user off" 구분 불가, probe 없이 baseline만.
        guard !enablement.knownIDs.isEmpty else {
            enablement.registerKnownProviders(currentIDs)
            return nil
        }

        let newIDs = enablement.registerKnownProviders(currentIDs)
        guard !newIDs.isEmpty else { return nil }
        AppLog.info(.config, "new providers since last run: \(newIDs.sorted()); probing local credentials")

        return Task {
            // 첫 런치 탐지와 동일한 동시 로컬 probe.
            let newProviders = providers.filter { newIDs.contains($0.provider.id) }
            let detected = await FirstRunSeeder.detectLocalProviders(newProviders)
            for id in detected.sorted() {
                // probe 중 사용자가 이미 켠 토글은 유지.
                guard !enablement.isEnabled(id) else { continue }
                AppLog.info(.config, "new provider \(id): credentials detected, enabling")
                enablement.setEnabled(true, for: id)
            }
        }
    }
}
