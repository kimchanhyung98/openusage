import Foundation

/// One extra Claude account card to build this launch: a custom-config-dir login found on this
/// computer whose account is distinct from the default card's. Cards render only while their source
/// is found (owner decision 4) — a record with no finding this launch simply builds no card.
struct ClaudeAccountCard: Equatable, Sendable {
    /// The account's stable record id (`claude@ab12cd34`) — the card id everywhere: layout, cache,
    /// CLI/API matching.
    var id: String
    /// The DERIVED card name (`ProviderAccountRecord.derivedDisplayName`) baked into the launch
    /// `Provider`. Never a rename: renames live only in the account registry and are resolved at
    /// render time, so a baked name can never be a stale copy of one.
    var displayName: String
    /// The config dir the card's credentials and spend logs are pinned to.
    var configDirPath: String
    /// The literal string whose hash names the dir's keychain item (see `ClaudeCredentialScope`).
    var keychainLiteral: String
    /// Same-account additional config dirs (rare): extra spend-log roots, never extra credentials.
    var extraLogRoots: [URL] = []
}

/// The launch-time account pass: read which account is signed in at each family's default home,
/// scan for extra Claude logins in custom config dirs, reconcile the account registry, import the
/// first managed profile when none exists yet, and expose what the rest of launch consumes — the
/// per-card identity map (snapshot-cache account stamp) and the extra-card build plan
/// (`ProviderCatalog`). Runs once per launch (app) or per invocation (one-shot CLI); a mid-run swap
/// is caught on the next launch.
@MainActor
struct ProviderAccountAssembly {
    /// Card id → the account identity signed in there this launch. A card whose identity didn't
    /// resolve is absent.
    let identityKeysByCard: [String: String]
    /// Family → the canonical home backing its bare/default card this launch. This comes from the
    /// same observer result as `identityKeysByCard`, rather than assuming a conventional dot-dir.
    var defaultHomePathsByFamily: [String: String] = [:]
    /// Extra Claude account cards found on this computer this launch, in stable id order.
    var claudeCards: [ClaudeAccountCard] = []
    /// Same-account custom config dirs discovered for the DEFAULT card's login: extra spend-log
    /// roots for the default scanner, never extra credentials.
    var defaultClaudeExtraLogRoots: [URL] = []
    /// Inactive managed profiles whose credentials live in OpenUsage's private Keychain snapshots.
    /// These are dashboard-only usage cards; they never redirect a terminal.
    var snapshotCards: [AccountUsageSnapshotCard] = []
    /// Bare family card ids whose local history is a managed shared-home total: sessions from
    /// several switched accounts share those logs, so the history syncs as a family total and must
    /// never be attributed to the currently selected profile's identity.
    var familyTotalHistoryCardIDs: Set<String> = []
    /// Explicit profile ownership for snapshot cards, whose synthetic provider ids cannot be
    /// derived from a configuration-home path.
    var profileIDsByCard: [String: String] = [:]
    /// Set while managed Codex switching is active: the shared `~/.codex` home whose `auth.json`
    /// the default Codex card must treat as its only credential source, so a stale `Codex Auth`
    /// Keychain item can never fall back to another account.
    var codexSharedAuthHome: String?
    /// True while managed Claude profiles exist: the default Claude card must not fall back to the
    /// Claude Desktop login, which can belong to a different account than the one switched into
    /// the shared home — an auth failure must surface as re-login, never as another account's usage.
    var claudeManagedSwitchActive: Bool = false

    /// `waitsForLoginShell`: true for the menu-bar app (a Finder/Dock launch inherits no shell
    /// exports, so the pass leans on the login-shell layers), false for the one-shot CLI (a terminal
    /// launch's process environment already carries the user's exports). The app passes its own
    /// `accountsStore` so the registry the pass reconciles is the same instance the UI observes for
    /// renames; the CLI omits it and gets a throwaway. `accountProfiles` likewise. First-account
    /// import is an explicit Settings action and never runs during this launch-time read pass.
    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool,
        accountProfiles: AccountProfilesStore? = nil
    ) -> ProviderAccountAssembly {
        // The identity read needs the login shell's exports (CLAUDE_CONFIG_DIR/CODEX_HOME name the
        // default homes), and it reads them through the very same reader the provider auth stores
        // use — `ProcessEnvironmentReader`, which pins identity-relevant keys to the persisted
        // shell-environment snapshot for the whole session, so identity and usage resolve the same
        // homes no matter when the async capture lands. The one unreadable state is a genuinely
        // FIRST Finder/Dock launch: capture still cold and no snapshot persisted yet — a
        // shell-exported home override would be invisible, so that family's read must be skipped
        // rather than misread as "no override". The skip is per family: a family whose home override
        // is already visible in the process environment (a terminal launch, `launchctl setenv`)
        // doesn't need the shell layers at all and still resolves.
        let shellFactsReadable = !waitsForLoginShell
            || LoginShellEnvironment.shared.capturedSuccessfully
            || ShellEnvironmentSnapshotStore.launchSnapshot != nil
        let families = shellFactsReadable
            ? ProviderAccountID.families
            : ProviderAccountID.families.filter { family in
                guard let key = Self.homeOverrideKeys[family] else { return false }
                return ProcessInfo.processInfo.environment[key]?.nilIfEmpty != nil
            }
        if families.count < ProviderAccountID.families.count {
            AppLog.info(.config, "account identity read skipped for \(ProviderAccountID.families.subtracting(families).sorted().joined(separator: ", ")): login shell cold and no shell-environment snapshot exists yet")
        }
        let profileStore = accountProfiles ?? AccountProfilesStore(defaults: defaults)

        // Managed Codex switching pins the provider AND the identity read to the shared
        // `~/.codex/auth.json` — the file the switch transaction owns. Gated on that file actually
        // existing: a legacy `~/.config/codex`-only login with an imported profile must keep
        // resolving through the historical source list until a switch (or the CLI itself) writes
        // the shared auth file.
        let sharedCodexAuthFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        let codexManaged = families.contains("codex")
            && !profileStore.profiles(family: "codex").isEmpty
            && FileManager.default.fileExists(atPath: sharedCodexAuthFile)
        // Managed Claude switching owns `~/.claude`: pin the identity read to that home (the
        // catalog pins the bare runtime the same way) so an ambient CLAUDE_CONFIG_DIR can't make
        // the app manage one account while observing another.
        let claudeManaged = families.contains("claude")
            && !profileStore.profiles(family: "claude").isEmpty
        let managedProfiles = profileStore.profiles
        let snapshotProfileIDs = Set(managedProfiles.compactMap { profile in
            AccountCredentialVault().contains(profile: profile) ? profile.id : nil
        })
        return make(
            observer: DefaultAccountObserver(
                pinsClaudeSharedHome: claudeManaged,
                pinsCodexSharedHome: codexManaged
            ),
            accountsStore: accountsStore ?? ProviderAccountsStore(defaults: defaults),
            families: families,
            claudeDiscovery: ClaudeConfigDirDiscovery(),
            accountProfiles: profileStore,
            managedProfiles: managedProfiles,
            snapshotProfileIDs: snapshotProfileIDs,
            codexSharedAuthHome: codexManaged
                ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
                : nil,
            claudeManagedSwitchActive: claudeManaged
        )
    }

    /// The environment variable that relocates each family's default home — the fact whose
    /// invisibility (shell layers unreadable AND not in the process environment) makes that family's
    /// identity read unsafe on a first launch.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// The environment-independent core, separated so tests inject a fixed observer, discovery, and
    /// scratch store. `families` limits the pass to the families whose home facts are readable this
    /// launch (see `make(defaults:waitsForLoginShell:)`); a family left out is simply not observed —
    /// no identity key, no reconciliation, exactly as if the pass never ran for it. `claudeDiscovery`
    /// is skipped alongside the claude family (its exclusion set needs the same home facts).
    static func make(
        observer: DefaultAccountObserver,
        accountsStore: ProviderAccountsStore,
        families: Set<String> = ProviderAccountID.families,
        claudeDiscovery: ClaudeConfigDirDiscovery? = nil,
        accountProfiles: AccountProfilesStore? = nil,
        managedProfiles: [AccountProfile] = [],
        snapshotProfileIDs: Set<String> = [],
        codexSharedAuthHome: String? = nil,
        claudeManagedSwitchActive: Bool = false
    ) -> ProviderAccountAssembly {
        var identityKeys: [String: String] = [:]
        var defaultHomePaths: [String: String] = [:]
        var observations: [ProviderAccountsStore.AccountObservation] = []

        let outcomes: [(family: String, outcome: DefaultAccountObserver.Outcome)] = [
            ("claude", { observer.observeClaude() }),
            ("codex", { observer.observeCodex() }),
        ].compactMap { family, observe in
            families.contains(family) ? (family, observe()) : nil
        }
        for (family, outcome) in outcomes {
            switch outcome {
            case .resolved(let identityKey, let label, let anchor):
                identityKeys[family] = identityKey
                defaultHomePaths[family] = anchor
                observations.append(ProviderAccountsStore.AccountObservation(
                    family: family,
                    identityKey: identityKey,
                    label: label,
                    sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
                ))
                AppLog.info(.config, "accounts: \(family) default identity resolved (\(ProviderAccountID.make(family: family, identityKey: identityKey)))")
            case .unresolved(let reason):
                // The soak signal for later phases: how often a real login can't name its account.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        // Extra Claude logins in custom config dirs. Guarded on the default read: when a default
        // login clearly EXISTS but can't be named (`unresolved`), accepting candidates could render
        // the very account the default card shows as a second card — skip them this launch instead.
        // A machine with no default login at all keeps accepting: there is nothing to duplicate,
        // and a custom-dir-only login should still get its card.
        var foundClaudeAccounts: [(identityKey: String, label: String?, dirs: [ClaudeConfigDirDiscovery.Finding])] = []
        var defaultClaudeExtraLogRoots: [URL] = []
        let claudeOutcome = outcomes.first { $0.family == "claude" }?.outcome
        if let claudeDiscovery, let claudeOutcome {
            if case .unresolved = claudeOutcome {
                AppLog.info(.config, "discovery: claude default login present but its identity is unreadable → skipping extra-account candidates this launch")
            } else {
                let defaultKey = identityKeys["claude"]
                let scan = claudeDiscovery.run()
                for note in scan.notes {
                    AppLog.info(.config, "discovery: \(note)")
                }
                var order: [String] = []
                var grouped: [String: [ClaudeConfigDirDiscovery.Finding]] = [:]
                for finding in scan.findings {
                    if grouped[finding.identityKey] == nil { order.append(finding.identityKey) }
                    grouped[finding.identityKey, default: []].append(finding)
                }
                for identityKey in order {
                    let findings = grouped[identityKey] ?? []
                    let sources = findings.map {
                        ProviderAccountSource(
                            kind: .configDir,
                            anchor: $0.anchorPath,
                            holdsDefaultSource: false,
                            keychainLiteral: $0.keychainLiteral
                        )
                    }
                    if identityKey == defaultKey {
                        // Same account as the default card: its dirs are extra spend-log roots on
                        // that card, never a second card — duplicate cards are structurally
                        // impossible because identity routes the source to the existing record.
                        defaultClaudeExtraLogRoots += findings.map { URL(fileURLWithPath: $0.anchorPath) }
                        if let index = observations.firstIndex(where: { $0.family == "claude" && $0.identityKey == identityKey }) {
                            observations[index].sources += sources
                        }
                        AppLog.info(.config, "discovery: \(findings.count) config dir(s) fold onto the default claude card (same account)")
                    } else {
                        observations.append(ProviderAccountsStore.AccountObservation(
                            family: "claude",
                            identityKey: identityKey,
                            label: findings.first?.label,
                            sources: sources
                        ))
                        foundClaudeAccounts.append((identityKey, findings.first?.label, findings))
                    }
                }
            }
        }

        let records = accountsStore.reconcile(with: observations)

        // The extra-card build plan: one card per distinct account found this launch, under its
        // reconciled record id.
        var claudeCards: [ClaudeAccountCard] = []
        for account in foundClaudeAccounts {
            guard let record = records.first(where: { $0.family == "claude" && $0.identityKey == account.identityKey }) else {
                continue
            }
            guard record.id != "claude" else {
                // The bare record's account has moved out of the default home into a config dir
                // while another login occupies the default. The bare CARD is the default home's
                // runtime, so this record can't render under its own id this launch. Proper swap
                // support re-points this in Phase 4; until then the parked account stays hidden.
                AppLog.warn(.config, "discovery: the claude record's account now lives in a config dir; its card is unavailable until swap support lands")
                continue
            }
            guard let primary = account.dirs.first else { continue }
            claudeCards.append(ClaudeAccountCard(
                id: record.id,
                displayName: record.derivedDisplayName,
                configDirPath: primary.anchorPath,
                keychainLiteral: primary.keychainLiteral,
                extraLogRoots: account.dirs.dropFirst().map { URL(fileURLWithPath: $0.anchorPath) }
            ))
            identityKeys[record.id] = account.identityKey
            AppLog.info(.config, "accounts: extra claude card \(record.id) from \(account.dirs.count) config dir(s)")
        }
        claudeCards.sort { $0.id < $1.id }

        // Inactive managed profiles render as snapshot cards — read-only usage backed by their
        // Keychain snapshot. A profile whose account is already visible through a home-backed card
        // this launch (the default home, or an ambient config dir) never gets a duplicate.
        let preferredProfileIDs = Dictionary(uniqueKeysWithValues: ProviderAccountID.families.compactMap { family in
            accountProfiles?.preferredProfileID(family: family).map { (family, $0) }
        })
        let observedIdentityKeys = Set(identityKeys.values)
        let snapshotCards = AccountUsageCardPlanner.snapshotCards(
            profiles: managedProfiles,
            preferredProfileIDs: preferredProfileIDs,
            availableSnapshotProfileIDs: snapshotProfileIDs,
            sharedHomeIdentityKeys: identityKeys
        ).filter { card in
            guard let profile = managedProfiles.first(where: { $0.id == card.profileID }) else { return false }
            return !observedIdentityKeys.contains(profile.identityKey)
        }
        let profileIDsByCard = Dictionary(uniqueKeysWithValues: snapshotCards.map { ($0.id, $0.profileID) })
        for card in snapshotCards {
            if let profile = managedProfiles.first(where: { $0.id == card.profileID }) {
                identityKeys[card.id] = profile.identityKey
            }
        }

        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            defaultHomePathsByFamily: defaultHomePaths,
            claudeCards: claudeCards,
            defaultClaudeExtraLogRoots: defaultClaudeExtraLogRoots,
            snapshotCards: snapshotCards,
            familyTotalHistoryCardIDs: Set(managedProfiles.filter { !$0.isArchived }.map(\.family)),
            profileIDsByCard: profileIDsByCard,
            codexSharedAuthHome: codexSharedAuthHome,
            claudeManagedSwitchActive: claudeManagedSwitchActive
        )
    }
}
