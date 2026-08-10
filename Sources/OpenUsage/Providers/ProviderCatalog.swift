import Foundation

/// 설치된 provider 집합과 canonical 순서. 메뉴바 앱과 one-shot CLI가 모두 여기서 runtime을 구성 — credential·refresh·pricing·normalization의 drift 방지.
@MainActor
enum ProviderCatalog {
    /// `snapshotCards`는 Keychain snapshot을 read-only로 렌더하는 비활성 등록 계정, `hasUnregisteredClaudeLogins`는 등록되지 않은 다른 Claude 로그인의 존재 신호(카드는 만들지 않고 fallback만 차단).
    /// `codexSharedAuthHome`은 관리형 Codex 전환 중 기본 Codex 카드를 switch transaction 소유의 shared `auth.json`에 고정 — 낡은 `Codex Auth` Keychain 항목의 다른 account fallback 금지. 빈 기본값은 기존 단일 카드 구성 유지.
    static func make(
        defaults: UserDefaults = .standard,
        hasUnregisteredClaudeLogins: Bool = false,
        defaultClaudeExtraLogRoots: [URL] = [],
        snapshotCards: [AccountUsageSnapshotCard] = [],
        codexSharedAuthHome: String? = nil,
        claudeManagedSwitchActive: Bool = false
    ) -> [ProviderRuntime] {
        // 기본 provider 순서: 기존 3개 먼저, 나머지는 display name 알파벳순. account 카드는 family 기본 카드 바로 뒤.
        var runtimes: [ProviderRuntime] = []
        runtimes.append(ClaudeProvider(
            // 이 Mac에 다른 Claude 로그인이 있으면 unpinned Desktop fallback이 그 로그인을 빌려 남의 usage를 표시할 수 있음 — 관리형 전환 중에도 동일하며, auth 실패는 다른 account의 usage가 아닌 재로그인으로 표면화되어야 함.
            // 관리형 전환 중에는 switch transaction이 `~/.claude`를 소유 — credential 읽기와 spend scan도 거기에 고정, ambient CLAUDE_CONFIG_DIR가 다른 home을 가리키게 두지 않음.
            authStore: ClaudeAuthStore(
                allowsDesktopFallback: !hasUnregisteredClaudeLogins && !claudeManagedSwitchActive,
                pinsSharedHome: claudeManagedSwitchActive
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                additionalRoots: defaultClaudeExtraLogRoots,
                pinsSharedHome: claudeManagedSwitchActive
            ),
            includePiUsage: !hasUnregisteredClaudeLogins
        ))
        for card in snapshotCards where card.family == "claude" {
            runtimes.append(claudeSnapshotRuntime(card: card))
        }
        runtimes.append(CodexProvider(
            authStore: codexSharedAuthHome.map { CodexAuthStore(scope: .home(path: $0)) } ?? CodexAuthStore()
        ))
        for card in snapshotCards where card.family == "codex" {
            runtimes.append(codexSnapshotRuntime(card: card))
        }
        runtimes += [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            KimiProvider(),
            KiroProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return runtimes
    }

    private static func claudeSnapshotRuntime(card: AccountUsageSnapshotCard) -> ClaudeProvider {
        ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: "Claude"),
            authStore: ClaudeAuthStore(scope: .accountSnapshot(profileID: card.profileID)),
            logUsageScanner: ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-snapshot:\(card.profileID)",
                rootsOverride: []
            ),
            includePiUsage: false
        )
    }

    private static func codexSnapshotRuntime(card: AccountUsageSnapshotCard) -> CodexProvider {
        CodexProvider(
            provider: CodexProvider.makeProvider(id: card.id, displayName: "Codex"),
            authStore: CodexAuthStore(scope: .accountSnapshot(profileID: card.profileID)),
            logUsageScanner: CodexLogUsageScanner(
                cacheIdentityOverride: "codex-snapshot:\(card.profileID)",
                rootsOverride: []
            ),
            includePiUsage: false
        )
    }
}
