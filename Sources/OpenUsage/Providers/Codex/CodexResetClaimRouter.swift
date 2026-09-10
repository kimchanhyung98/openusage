import Foundation
import SwiftUI

/// Codex 카드마다 `CodexResetClaimService` 하나.
/// Reset-credit claim은 앱의 유일한 provider-API write이자 비가역 — 카드에서 탭한 claim은 반드시 그 카드 자신의 `authStore`/`usageClient`로만 실행, 다른 계정의 credential 소비 차단.
@MainActor
final class CodexResetClaimRouter {
    private var servicesByCard: [String: CodexResetClaimService]
    private let refreshAfterClaim: (String) async -> Void
    private var generation = 0
    private var identityKeysByCard: [String: String] = [:]

    /// `refreshAfterClaim`은 claim한 카드의 provider id 수신 — container가 공용 bounded-retry 강제 refresh 주입 (`AppContainer` 참고).
    init(
        providers: [CodexProvider],
        identityKeys: [String: String] = [:],
        refreshAfterClaim: @escaping (String) async -> Void
    ) {
        self.servicesByCard = [:]
        self.refreshAfterClaim = refreshAfterClaim
        reconfigure(providers: providers, identityKeys: identityKeys)
    }

    /// 카드 하나의 claim service — Codex runtime 없는 카드(미등록 id, managed home 미발견)는 `nil`, row는 read-only 렌더링.
    func service(for cardID: String) -> CodexResetClaimService? {
        servicesByCard[cardID]
    }

    /// 현재 카탈로그 전체로 라우팅 테이블 재구성 — 같은 id 재등록은 교체, 이탈 카드는 제거 (stale credential로 claim 가능한 상태 방지).
    func reconfigure(providers: [CodexProvider], identityKeys: [String: String] = [:]) {
        generation &+= 1
        identityKeysByCard = identityKeys
        let boundGeneration = generation
        let refreshAfterClaim = refreshAfterClaim
        servicesByCard = Dictionary(uniqueKeysWithValues: providers.map { provider in
            let cardID = provider.provider.id
            let boundIdentityKey = identityKeys[cardID]
            return (cardID, CodexResetClaimService(
                authStore: provider.authStore,
                usageClient: provider.usageClient,
                refreshAfterClaim: { [weak self] in
                    // 다른 카드 변경은 허용하되, identity 미해석 카드는 같은 catalog에서만 후속 조회.
                    guard let self,
                          self.servicesByCard[cardID] != nil,
                          self.identityKeysByCard[cardID] == boundIdentityKey,
                          boundIdentityKey != nil || self.generation == boundGeneration
                    else {
                        AppLog.info(LogTag.plugin("codex"), "post-claim refresh skipped: account binding changed")
                        AppDiagnostics.record(.postClaimRefresh, result: .bindingChanged, providerID: "codex")
                        return
                    }
                    await refreshAfterClaim(cardID)
                }
            ))
        })
    }
}

/// Environment로 resets popover에 claim router 전달 — `nil`(기본값: preview·share-card 렌더·reorder preview)이면 timeline read-only, "Use" 없음.
private struct CodexResetClaimRouterKey: EnvironmentKey {
    static let defaultValue: CodexResetClaimRouter? = nil
}

extension EnvironmentValues {
    var codexResetClaim: CodexResetClaimRouter? {
        get { self[CodexResetClaimRouterKey.self] }
        set { self[CodexResetClaimRouterKey.self] = newValue }
    }
}
