import Foundation
import Observation

/// Composition root: owns the (constant) registry and the (mutable) stores, injected
/// into the SwiftUI environment.
@MainActor
@Observable
final class AppContainer {
    private(set) var registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    /// Opt-in private iCloud document sync for additive machine-local daily history.
    let iCloudSync: ICloudUsageSyncStore
    /// Single source of truth for which providers the user has turned off. Both stores consult it (via
    /// injected closures) and the Customize provider list drives it.
    let enablement: ProviderEnablementStore
    /// Providers that need a user-supplied API key (currently OpenRouter and Z.ai), conforming to
    /// `APIKeyManaging`. Each matching Customize provider detail shows an API Key section and writes
    /// changes through the capability. Empty when no installed provider needs a user key.
    let apiKeyProviders: [any APIKeyManaging]
    /// Quota pace notification preferences (three independent triggers). Drives the Settings section
    /// and is read by `WidgetDataStore.evaluateNotifications`.
    let notificationSettings: NotificationSettingsStore
    /// Anonymous, opt-in usage telemetry (daily rollups). Exposed so Settings can toggle it and the
    /// app-termination hook can flush any queued events.
    let telemetry: TelemetryRecorder
    /// Source of truth for the popover's transparency: the persisted Increase Transparency toggle, the
    /// ephemeral secret-code easter-egg state, and the system accessibility flags it yields to. Read by both
    /// the SwiftUI surface and the AppKit panel (`StatusItemController`).
    let transparency: PopoverTransparencyStore
    /// The menu bar's screen-share privacy mode: the persisted Hide From Screen Share toggle
    /// plus the live capture signal. Read by `StatusItemImageUpdater` to swap the strip for the
    /// wordmark while the screen is shared or recorded.
    let privacy: MenuBarPrivacyStore
    /// One-time onboarding state (the first-run Customize hint card). Only ever marked pending by
    /// `FirstRunSeeder` on a fresh install, so existing installs never see the card.
    let onboarding: OnboardingStore
    /// Claims Codex rate-limit reset credits from the resets popover (the app's only provider-API
    /// write), routed per card: every Codex card's claim runs through that card's own auth store and
    /// usage client, so an irreversible claim always spends the same account's credential the card
    /// shows. `nil` only if the Codex provider were ever removed from the registry. Injected into the
    /// view tree via `\.codexResetClaim`.
    let codexResetClaim: CodexResetClaimRouter
    /// The account registry the launch pass reconciled. The UI observes it live: a rename
    /// (`customLabel`) re-titles the card everywhere without a relaunch.
    let accounts: ProviderAccountsStore
    /// The managed launch-profile registry (`AccountProfilesStore`) the launch account pass scanned.
    /// Kept as the single shared instance so the Settings account UI reads (and reloads) the same
    /// state the pass used.
    let accountProfiles: AccountProfilesStore
    /// Card id → managed profile id for cards that were assembled from a registered launch home.
    /// The mapping is stable across label edits, so the dashboard can select the same Personal/Work
    /// profile that Settings uses without making profile labels card IDs.
    private var accountProfileIDsByCardID: [String: String]
    /// The provider runtimes, kept so on-demand credential detection (the Customize "Reset All" reseed)
    /// can re-probe `hasLocalCredentials()` the same way first-run seeding does.
    private var providers: [ProviderRuntime]
    /// Read-only usage API on 127.0.0.1:6736 for other local apps (silently off when the port is taken).
    private let localAPI: LocalUsageServer
    // A `let` of a `Sendable` `Task` is implicitly nonisolated, so the nonisolated `deinit` can cancel it.
    private let refreshTask: Task<Void, Never>
    /// The fresh-install credential-detection pass (see `FirstRunSeeder`); `nil` on every later launch.
    private let seedTask: Task<Void, Never>?
    /// The new-provider credential-detection pass (see `NewProviderSeeder`); `nil` unless this launch is
    /// the first with a provider the install has never seen.
    private let newProviderTask: Task<Void, Never>?
    /// Persists a fresh `ShellEnvironmentSnapshot` once the login-shell capture completes, so the next
    /// launch can read shell-exported facts (provider home overrides) even when its own capture is slow.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>

    /// `isFreshInstall` must be captured by the caller BEFORE `SettingsMigrator.migrate()` runs (the
    /// migrator's schema stamp makes the defaults domain non-empty). See `AppDelegate`.
    init(isFreshInstall: Bool = false) {
        // Capture the user's login-shell environment off-main so provider keys exported in a shell
        // profile (e.g. OPENROUTER_API_KEY) resolve in a Finder/Dock-launched build, not only when
        // run from a terminal. Warmed here so the first refresh finds the cache ready.
        LoginShellEnvironment.shared.prewarm()
        // Once the capture lands, persist its identity-relevant facts so the NEXT launch has them
        // even if that launch's own capture is slow (see `ShellEnvironmentSnapshot`).
        self.shellEnvironmentSnapshotTask = ShellEnvironmentSnapshotStore(defaults: .standard).startRefreshTask()
        // The launch account pass: which account is signed in at each family's default home, plus
        // the config-dir scan for extra Claude logins. Feeds the snapshot cache's account stamp,
        // reconciles the account registry, and hands the catalog its extra-card build plan.
        // `accountProfiles` is created here (before the pass) so the pass and the Settings account
        // UI share one instance.
        let accounts = ProviderAccountsStore()
        let accountProfiles = AccountProfilesStore()
        let accountAssembly = ProviderAccountAssembly.make(
            accountsStore: accounts,
            waitsForLoginShell: true,
            accountProfiles: accountProfiles
        )
        self.accounts = accounts
        self.accountProfiles = accountProfiles
        self.accountProfileIDsByCardID = Self.accountProfileIDsByCardID(
            assembly: accountAssembly,
            profiles: accountProfiles
        )

        let providers = ProviderCatalog.make(
            claudeCards: accountAssembly.claudeCards,
            defaultClaudeExtraLogRoots: accountAssembly.defaultClaudeExtraLogRoots,
            snapshotCards: accountAssembly.snapshotCards,
            codexSharedAuthHome: accountAssembly.codexSharedAuthHome,
            claudeManagedSwitchActive: accountAssembly.claudeManagedSwitchActive
        )
        let registry = WidgetRegistry.from(providers)
        let apiKeyProviders = providers.compactMap { $0 as? any APIKeyManaging }
        let enablement = ProviderEnablementStore()
        let notificationSettings = NotificationSettingsStore()
        let layout = LayoutStore(
            registry: registry,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) }
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: providers,
            isProviderEnabled: { [enablement] in enablement.isEnabled($0) },
            orderedDescriptors: { [layout] in layout.visiblePlaced.compactMap { layout.descriptor(for: $0) } },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: accountAssembly.identityKeysByCard,
            familyTotalHistoryCardIDs: accountAssembly.familyTotalHistoryCardIDs,
            resolveDisplayName: { [accounts] in accounts.resolvedDisplayName(cardID: $0) }
        )
        let iCloudSync = ICloudUsageSyncStore(dataStore: dataStore)
        // Re-enabling a provider should fetch it promptly, so clear any leftover failure backoff before
        // the enablement wake refreshes. `weak` breaks the cycle (dataStore already captures enablement).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore, weak iCloudSync] in
            dataStore?.providerEnablementDidChange()
            iCloudSync?.scheduleWrite()
        }
        // Fresh installs start minimal: seed the enabled-provider list (Claude/Codex/Kimi right away,
        // then the detected set once the local credential probe finishes). No-op on every later launch.
        let onboarding = OnboardingStore()
        self.seedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // Providers added by an update get the same credential detection on their first launch — enabled
        // only when the user actually has the tool. Runs every launch; a no-op unless the registry has a
        // provider this install has never seen (fresh installs were just baselined by FirstRunSeeder).
        self.newProviderTask = NewProviderSeeder.reconcileIfNeeded(
            providers: providers,
            enablement: enablement
        )
        self.providers = providers
        self.onboarding = onboarding
        self.registry = registry
        self.enablement = enablement
        self.apiKeyProviders = apiKeyProviders
        self.notificationSettings = notificationSettings
        self.layout = layout
        self.dataStore = dataStore
        self.iCloudSync = iCloudSync

        // The resets popover's claim router: one claim service per Codex card, each sharing ITS card's
        // credential loading and HTTP client so a claim's auth can't drift from the provider it was
        // tapped on — an irreversible claim must spend the same account's credential the card shows.
        // A successful claim forces a refresh of that card so the meters and credit count reconcile
        // before the popover shows its result. The forced refresh returns `.skipped` when another
        // refresh already owns the provider — and that in-flight probe may carry *pre-claim* usage —
        // so retry until this refresh actually runs (bounded; the racing probe finishes in seconds).
        let codexProviders = providers.compactMap { $0 as? CodexProvider }
        self.codexResetClaim = CodexResetClaimRouter(
            providers: codexProviders,
            refreshAfterClaim: { [weak dataStore] providerID in
                // The bound must outlast the provider's slowest refresh: usage fetch (10s timeout)
                // + token refresh (15s) + usage retry (10s) + reset-credit fetch (10s) ≈ 45s. The
                // common race (the periodic timer's probe) clears in a couple of seconds; the
                // pathological one keeps the popover's honest "Resetting…" up rather than showing
                // a success banner over pre-claim meters. A `.failed` probe is retried a few times
                // too — a transient flake right after the claim must not strand pre-claim meters
                // behind a success banner — before giving up loudly (the provider error already
                // shows on the card, so the staleness isn't silent).
                var failures = 0
                for attempt in 0..<45 {
                    guard let dataStore else { return }
                    switch await dataStore.refresh(providerID: providerID, force: true) {
                    case .refreshed, .cacheHit, .backedOff:
                        return
                    case .failed:
                        failures += 1
                        guard failures < 3 else {
                            AppLog.error(LogTag.plugin("codex"), "post-claim refresh failed \(failures) times; meters may lag until the next cycle")
                            return
                        }
                        try? await Task.sleep(for: .seconds(2))
                    case .skipped:
                        AppLog.info(LogTag.plugin("codex"), "post-claim refresh waiting out an in-flight refresh (attempt \(attempt + 1))")
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                AppLog.error(LogTag.plugin("codex"), "post-claim refresh kept being skipped; meters may lag until the next cycle")
            }
        )

        // Anonymous, opt-in usage telemetry (two daily-rollup events). Its state lives in a dedicated
        // UserDefaults suite, kept separate from app settings so the user's sharing choice and the
        // install id stay independent of any settings change. The snapshot closure reads the live
        // layout/enablement so `app_daily_active` always reflects the current configuration.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [enablement, layout, dataStore] in
                // Report the *active* configuration: a metric whose provider is turned off is hidden
                // from the dashboard and menu bar, so exclude it here too — keeping the metric arrays
                // consistent with `enabledProviders` (which is also enablement-filtered).
                let providerOn: (String) -> Bool = { metricID in
                    guard let providerID = layout.registry.descriptor(id: metricID)?.providerID else { return false }
                    return enablement.isEnabled(providerID)
                }
                return TelemetryConfigSnapshot(
                enabledProviders: dataStore.knownProviderIDs.filter { enablement.isEnabled($0) },
                    enabledMetricIDs: layout.placed.map(\.descriptorID).filter(providerOn),
                    pinnedMetricIDs: layout.pinnedMetricIDs.filter(providerOn),
                    expandedMetricIDs: layout.expandedMetricIDs.filter(providerOn),
                    menuBarStyle: layout.menuBarStyle.rawValue
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        self.telemetry = telemetry
        self.transparency = PopoverTransparencyStore()
        self.privacy = MenuBarPrivacyStore()
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore, accounts] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.orderedProviderIDs().filter { enablement.isEnabled($0) },
                knownIDs: Set(dataStore.knownProviderIDs),
                snapshots: dataStore.snapshots,
                limitDescriptors: dataStore.limitDescriptorsByProvider,
                errors: dataStore.providerErrors
            )
            // API output is human-read too: resolve card titles at respond time so renames show,
            // exactly like every UI surface.
            .resolvingDisplayNames(accounts.resolvedDisplayNamesByCardID)
        })
        self.refreshTask = Self.startPeriodicRefresh(dataStore: dataStore, telemetry: telemetry)
        localAPI.start()
        // Become the notification-center delegate so banners show while frontmost — a menu-bar accessory
        // effectively always is. Notification authorization is requested the first time a trigger is
        // turned on in Settings, not at launch — triggers default off. No-op under tests.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit {
        refreshTask.cancel()
        seedTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
    }

    /// The name a card renders under right now — the app-side face of the one resolver
    /// (`ProviderAccountRecord.resolvedDisplayName`). Live: a rename in the account registry
    /// re-titles the card everywhere without a relaunch. Non-account providers (no record) keep
    /// their static display name; `Provider.displayName` itself only ever carries the derived
    /// default, so the fallback can never be a stale rename.
    func displayName(for provider: Provider) -> String {
        accounts.resolvedDisplayName(cardID: provider.id) ?? provider.displayName
    }

    /// The managed profile label for a usage card, if that card is backed by a managed profile.
    func accountProfileLabel(for cardID: String) -> String? {
        guard let profileID = accountProfileIDsByCardID[cardID] else { return nil }
        return accountProfiles.profile(id: profileID)?.label
    }

    /// The visible account card backed by a family's currently selected managed profile.
    func preferredAccountCardID(for family: String, among cardIDs: [String]) -> String? {
        guard let profileID = accountProfiles.preferredProfileID(family: family) else { return nil }
        return cardIDs.first { accountProfileIDsByCardID[$0] == profileID }
    }

    /// A successful Settings account switch updates both account-derived usage surfaces once: the
    /// dashboard selector and the selected family's menu-bar stars. Later dashboard picker changes
    /// stay view-only and never run the terminal switch or alter menu-bar stars again.
    func syncDashboardUsageAccount(to profile: AccountProfile) {
        guard let cardID = DashboardUsageAccountSelection.selectAfterAccountSwitch(
            family: profile.family,
            availableCardIDs: registry.providers.map(\.id)
        ) else {
            return
        }
        layout.retargetMenuBarPins(for: profile.family, to: cardID)
        Task { await dataStore.refreshAfterAccountSelection(providerID: cardID) }
    }

    /// Adds or removes account-scoped provider cards immediately after Settings changes a managed
    /// profile. The root stores remain stable, so the already-open dashboard and status item pick up
    /// the new registry without a process restart.
    func refreshAccountCatalog() {
        let assembly = ProviderAccountAssembly.make(
            accountsStore: accounts,
            waitsForLoginShell: true,
            accountProfiles: accountProfiles
        )
        let nextProviders = ProviderCatalog.make(
            claudeCards: assembly.claudeCards,
            defaultClaudeExtraLogRoots: assembly.defaultClaudeExtraLogRoots,
            snapshotCards: assembly.snapshotCards,
            codexSharedAuthHome: assembly.codexSharedAuthHome,
            claudeManagedSwitchActive: assembly.claudeManagedSwitchActive
        )
        let nextRegistry = WidgetRegistry.from(nextProviders)
        let previousIDs = Set(registry.providers.map(\.id))
        let addedIDs = Set(nextRegistry.providers.map(\.id)).subtracting(previousIDs)

        registry = nextRegistry
        providers = nextProviders
        accountProfileIDsByCardID = Self.accountProfileIDsByCardID(
            assembly: assembly,
            profiles: accountProfiles
        )
        layout.replaceRegistry(nextRegistry)
        dataStore.replaceProviderCatalog(
            registry: nextRegistry,
            providers: nextProviders,
            identityKeys: assembly.identityKeysByCard,
            familyTotalHistoryCardIDs: assembly.familyTotalHistoryCardIDs
        )

        for providerID in addedIDs.sorted() {
            _ = enablement.registerKnownProviders([providerID])
            let family = ProviderAccountID.family(of: providerID)
            if ProviderAccountID.families.contains(family), enablement.isEnabled(family) {
                enablement.setEnabled(true, for: providerID)
            }
        }
        codexResetClaim.reconfigure(providers: nextProviders.compactMap { $0 as? CodexProvider })
        for providerID in addedIDs where enablement.isEnabled(providerID) {
            Task { await dataStore.refreshAfterAccountSelection(providerID: providerID) }
        }
    }

    /// Account-specific runtimes are alternate views of one provider. The Customize master toggle
    /// therefore always enables or disables every account card in that provider family together.
    func setProviderEnabled(_ enabled: Bool, for providerID: String) {
        let family = ProviderAccountID.family(of: providerID)
        if ProviderAccountID.families.contains(family) {
            for provider in providers where ProviderAccountID.family(of: provider.provider.id) == family {
                enablement.setEnabled(enabled, for: provider.provider.id)
            }
        } else {
            enablement.setEnabled(enabled, for: providerID)
        }
    }

    /// Whether the card has an account record a rename can attach to (accounts-model families only,
    /// and only once the account's identity has been observed at least once).
    func canRename(_ providerID: String) -> Bool {
        accounts.records.contains { $0.id == providerID }
    }

    /// Re-runs first-launch credential detection on demand — the enablement half of the Customize
    /// "Reset All" action (`LayoutStore.resetToDefault` handles metrics, order, pins, and expansion).
    /// Delegates to `FirstRunSeeder.reseed`; returns its detection task so callers can await it.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    static func accountProfileIDsByCardID(
        assembly: ProviderAccountAssembly,
        profiles: AccountProfilesStore
    ) -> [String: String] {
        // Profiles map to cards by identity, never by path. The selected profile answers for the
        // bare family card (the shared-home runtime carries its authentication); every inactive
        // profile owns its snapshot card. A card whose account matches a managed profile's identity
        // — the ambient config-dir case — attaches by that identity too.
        var result = assembly.profileIDsByCard
        for family in AccountProfilesStore.supportedFamilies {
            guard let selected = profiles.preferredProfile(family: family) else { continue }
            if let observed = assembly.identityKeysByCard[family], observed != selected.identityKey {
                // Someone signed the shared home into a different account outside OpenUsage; the
                // bare card shows that login, so the selected profile must not claim its label.
                continue
            }
            result[family] = selected.id
        }
        for card in assembly.claudeCards {
            guard let identityKey = assembly.identityKeysByCard[card.id],
                  let profile = profiles.profiles(family: "claude").first(where: { $0.identityKey == identityKey })
            else { continue }
            result[card.id] = profile.id
        }
        return result
    }

    /// Drives live updates: refresh on launch, then again every refresh interval. Each pass honors the
    /// cache, so it only hits the network once a snapshot has actually expired. `@Observable` propagates
    /// the resulting snapshot changes to the menu-bar label and any open widgets, so the UI refreshes on
    /// its own instead of only when the popover opens.
    ///
    /// Between passes the loop sleeps via `RefreshWakeSignal`, which wakes it early when the user
    /// enables/disables a provider so a newly-enabled provider is fetched promptly instead of waiting out
    /// the full interval. The signal subscribes BEFORE the first pass and buffers, so an enablement change
    /// landing while a pass is still running (first-run credential detection, `NewProviderSeeder`, the
    /// Customize "Reset All" reseed — all of which typically finish faster than the network fetches) is
    /// never lost. Each pass still honors the cache (and the per-provider failure backoff), so an early
    /// wake only hits the network for a provider whose snapshot has actually expired.
    ///
    /// The wake is deliberately scoped to `ProviderEnablementStore.didChangeNotification` — NOT the
    /// firehose `UserDefaults.didChangeNotification`, which fires for the app's own snapshot-cache writes,
    /// Sparkle's update bookkeeping, and unrelated global-domain changes from other processes. Waking on
    /// that, with no minimum interval before re-refreshing, collapsed the fixed 5-minute cadence into a
    /// refresh storm.
    private static func startPeriodicRefresh(dataStore: WidgetDataStore, telemetry: TelemetryRecorder) -> Task<Void, Never> {
        Task {
            let wakeSignal = RefreshWakeSignal()
            while !Task.isCancelled {
                await dataStore.refreshAll()
                // Re-evaluate quota pace milestones every tick — after the refresh so it sees fresh data,
                // and on every loop (not just on a fetch) so pace worsening from elapsed time alone still
                // alerts even with the popover closed.
                await dataStore.evaluateNotifications()
                // Day-rollover beat: emits `app_daily_active` once per local day and flushes any
                // prior-day provider rollups. Runs on launch and every interval, so always-running
                // instances still produce a daily-active signal.
                telemetry.tick()
                await wakeSignal.waitForWake(timeout: RefreshSetting.interval)
            }
        }
    }
}
