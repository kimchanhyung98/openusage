import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    /// `claudeCards` carries the extra Claude account cards found by the launch account pass
    /// (`ProviderAccountAssembly`). Each becomes an ordinary runtime inserted right after the default
    /// Claude card, with credentials and usage logs pinned to exactly its own config dir.
    /// `snapshotCards` are inactive managed profiles rendered read-only from their Keychain
    /// snapshots. `codexSharedAuthHome`, set while managed Codex switching is active, pins the
    /// default Codex card to the shared `auth.json` the switch transaction owns — a stale
    /// `Codex Auth` Keychain item must never fall back to another account. The empty defaults keep
    /// the historical single-card set for focused tests and callers that skip the account pass.
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        defaultClaudeExtraLogRoots: [URL] = [],
        snapshotCards: [AccountUsageSnapshotCard] = [],
        codexSharedAuthHome: String? = nil,
        claudeManagedSwitchActive: Bool = false
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Account cards slot in right after
        // their family's default card.
        //
        // Every baked `Provider.displayName` here is the DERIVED default — renames live only in the
        // account registry and are resolved at render time (`ProviderAccountRecord.resolvedDisplayName`),
        // so a baked name can never be a stale copy of one.
        var runtimes: [ProviderRuntime] = []
        runtimes.append(ClaudeProvider(
            // Once extra Claude cards exist, an unpinned Desktop fallback could borrow a login that
            // belongs to one of them — fetching that account's usage onto the default card. Desktop
            // returns as its own properly-pinned source kind in Phase 3. The same rule applies while
            // managed switching is active: the Desktop login can be a different account than the one
            // switched into the shared home, and an auth failure must surface as re-login rather
            // than another account's usage.
            // While managed switching is active the switch transaction owns `~/.claude`, so the
            // card's credential reads and spend scan pin there too — an ambient CLAUDE_CONFIG_DIR
            // must not point the bare card at a different home than the one being managed.
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

    /// An extra Claude account card: same provider machinery, credentials and logs pinned to one
    /// login. The scanner's parse cache is partitioned per card so distinct homes never share
    /// records.
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
