import Foundation

/// 설치된 provider 집합과 canonical 순서. 메뉴바 앱과 one-shot CLI가 모두 여기서 runtime을 구성 — credential·refresh·pricing·normalization의 drift 방지.
@MainActor
enum ProviderCatalog {
    /// `claudeCards`는 launch account pass(`ProviderAccountAssembly`)가 찾은 추가 Claude 카드(기본 카드 뒤 삽입, 자기 config dir에 고정), `snapshotCards`는 Keychain snapshot을 read-only로 렌더하는 비활성 managed profile.
    /// `codexSharedAuthHome`은 관리형 Codex 전환 중 기본 Codex 카드를 switch transaction 소유의 shared `auth.json`에 고정 — 낡은 `Codex Auth` Keychain 항목의 다른 account fallback 금지. 빈 기본값은 기존 단일 카드 구성 유지.
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        defaultClaudeExtraLogRoots: [URL] = [],
        snapshotCards: [AccountUsageSnapshotCard] = [],
        codexSharedAuthHome: String? = nil,
        claudeManagedSwitchActive: Bool = false
    ) -> [ProviderRuntime] {
        // 기본 provider 순서: 기존 3개 먼저, 나머지는 display name 알파벳순. account 카드는 family 기본 카드 바로 뒤.
        // 여기 박힌 `Provider.displayName`은 DERIVED 기본값 — rename은 account registry에만 살고 렌더 시 해석(`ProviderAccountRecord.resolvedDisplayName`)되므로 stale 복사본 불가.
        var runtimes: [ProviderRuntime] = []
        runtimes.append(ClaudeProvider(
            // 추가 Claude 카드가 있으면 unpinned Desktop fallback이 그 카드의 로그인을 빌려 기본 카드에 남의 usage를 표시할 수 있음 — 관리형 전환 중에도 동일하며, auth 실패는 다른 account의 usage가 아닌 재로그인으로 표면화되어야 함.
            // 관리형 전환 중에는 switch transaction이 `~/.claude`를 소유 — credential 읽기와 spend scan도 거기에 고정, ambient CLAUDE_CONFIG_DIR가 다른 home을 가리키게 두지 않음.
            authStore: ClaudeAuthStore(
                allowsDesktopFallback: claudeCards.isEmpty && !claudeManagedSwitchActive,
                pinsSharedHome: claudeManagedSwitchActive
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                additionalRoots: defaultClaudeExtraLogRoots,
                pinsSharedHome: claudeManagedSwitchActive
            ),
            includePiUsage: claudeCards.isEmpty
        ))
        for card in claudeCards {
            runtimes.append(claudeAccountRuntime(card: card))
        }
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

    /// 추가 Claude account 카드: 같은 provider 기계장치에 credential·log만 한 로그인에 고정. parse cache는 카드별 partition — 서로 다른 home이 record를 공유하지 않음.
    private static func claudeAccountRuntime(card: ClaudeAccountCard) -> ClaudeProvider {
        ClaudeProvider(
            provider: ClaudeProvider.makeProvider(id: card.id, displayName: card.displayName),
            authStore: ClaudeAuthStore(
                scope: .configDir(path: card.configDirPath, keychainLiteral: card.keychainLiteral)
            ),
            logUsageScanner: ClaudeLogUsageScanner(
                cacheIdentityOverride: "claude-account:\(card.id)",
                rootsOverride: [URL(fileURLWithPath: card.configDirPath)] + card.extraLogRoots
            ),
            includePiUsage: false
        )
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
