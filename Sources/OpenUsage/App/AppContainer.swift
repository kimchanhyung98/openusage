import Foundation
import Observation

/// 메인 액터에서 한 번 설정되는 장수 task의 nonisolated 종료 소유자.
private final class AccountRefreshTaskHolder: @unchecked Sendable {
    var task: Task<Void, Never>?

    deinit {
        task?.cancel()
    }
}

/// 상수 registry와 가변 store를 소유해 SwiftUI environment에 주입하는 composition root.
@MainActor
@Observable
final class AppContainer {
    private(set) var registry: WidgetRegistry
    let layout: LayoutStore
    let dataStore: WidgetDataStore
    /// 머신 로컬 일간 히스토리의 opt-in iCloud 문서 동기화.
    let iCloudSync: ICloudUsageSyncStore
    /// 사용자가 끈 provider의 단일 source of truth. 두 store가 주입 closure로 참조, Customize provider 목록이 변경 주도.
    let enablement: ProviderEnablementStore
    let apiKeyProviders: [any APIKeyManaging]
    /// Settings와 알림 평가가 공유하는 독립 트리거 3종.
    let notificationSettings: NotificationSettingsStore
    /// Settings opt-in 토글과 앱 종료 flush가 공유하는 일간 rollup.
    let telemetry: TelemetryRecorder
    /// SwiftUI surface와 AppKit panel이 공유하는 Popover 투명도 단일 상태.
    let transparency: PopoverTransparencyStore
    /// 캡처 중 strip을 wordmark로 교체하도록 status item updater가 참조.
    let privacy: MenuBarPrivacyStore
    /// 1회성 onboarding 상태. 신규 설치에서만 `FirstRunSeeder`가 pending 표시 — 기존 설치는 hint 카드 미노출.
    let onboarding: OnboardingStore
    /// Codex reset credit claim 라우터 (앱 유일의 provider-API 쓰기). 카드별 자체 auth store·usage client 경유 —
    /// 되돌릴 수 없는 claim이 항상 카드가 표시하는 계정의 credential을 사용하도록 보장.
    let codexResetClaim: CodexResetClaimRouter
    /// 런치 패스가 reconcile한 account registry. 계정 이름은 여기서 render 시점에 해석.
    let accounts: ProviderAccountsStore
    /// 관리형 launch-profile registry. 런치 account 패스와 Settings 계정 UI가 공유하는 단일 인스턴스.
    let accountProfiles: AccountProfilesStore
    /// 카드 id → 관리형 profile id 매핑. label 편집과 무관하게 안정 — dashboard가 Settings와 같은 profile 선택 가능.
    private var accountProfileIDsByCardID: [String: String]
    /// 현재 provider catalog를 만든 account 입력 — 동일 입력의 재조립은 in-flight refresh를 무효화하지 않음.
    private var accountAssembly: ProviderAccountAssembly
    /// 온디맨드 credential 재탐지(Customize "Reset All")용으로 보관하는 provider runtime 목록.
    private var providers: [ProviderRuntime]
    /// 127.0.0.1:6736의 읽기 전용 로컬 usage API (포트 점유 시 조용히 비활성).
    private let localAPI: LocalUsageServer
    /// 주기 refresh와 shared-home 재인증 reconciliation task 수명.
    private let refreshTask = AccountRefreshTaskHolder()
    /// Codex 인증·usage refresh와 분리된 공개 Reset Watch 조회 주기.
    private let resetWatchCoordinator: CodexResetWatchCoordinator
    /// Settings·주기·수동 refresh가 같은 외부 Claude 로그인을 동시에 귀속하지 않도록 직렬화.
    private var isReconcilingExternalClaudeAuthentication = false
    /// 신규 설치 credential 탐지 패스 (`FirstRunSeeder` 참고); 이후 런치에서는 `nil`.
    private let seedTask: Task<Void, Never>?
    /// 신규 provider credential 탐지 패스 (`NewProviderSeeder` 참고); 처음 보는 provider가 없으면 `nil`.
    private let newProviderTask: Task<Void, Never>?
    /// login-shell 캡처 완료 시 `ShellEnvironmentSnapshot` 영속화 — 다음 런치가 자체 캡처 완료 전에도 shell 정보 참조 가능.
    private let shellEnvironmentSnapshotTask: Task<Void, Never>

    /// `isFreshInstall`은 `SettingsMigrator.migrate()` 실행 전 호출자 캡처 필수 — migrator의 schema stamp가
    /// defaults 도메인을 non-empty로 변경. `AppDelegate` 참고.
    init(isFreshInstall: Bool = false) {
        // login-shell 환경 off-main 선캡처 — Finder/Dock 런치에서도 shell profile의 provider key 해석 가능.
        LoginShellEnvironment.shared.prewarm()
        // 캡처 완료 시 identity 관련 사실 영속화 — 다음 런치용 (`ShellEnvironmentSnapshot` 참고).
        self.shellEnvironmentSnapshotTask = ShellEnvironmentSnapshotStore(defaults: .standard).startRefreshTask()
        // 런치 account 패스: family별 기본 home의 로그인 계정 확인 + config-dir 스캔(같은 계정 로그 합산·fallback gate용).
        // `accountProfiles`는 패스와 Settings 계정 UI가 한 인스턴스를 공유하도록 패스 이전에 생성.
        let accounts = ProviderAccountsStore()
        let accountProfiles = AccountProfilesStore()
        let accountAssembly = ProviderAccountAssembly.make(
            accountsStore: accounts,
            waitsForLoginShell: true,
            accountProfiles: accountProfiles
        )
        self.accounts = accounts
        self.accountProfiles = accountProfiles
        self.accountAssembly = accountAssembly
        self.accountProfileIDsByCardID = Self.accountProfileIDsByCardID(
            assembly: accountAssembly,
            profiles: accountProfiles
        )

        let providers = ProviderCatalog.make(
            hasUnregisteredClaudeLogins: accountAssembly.hasUnregisteredClaudeLogins,
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
            orderedDescriptors: { [layout] in layout.orderedRenderedDescriptors() },
            notificationSettings: { notificationSettings },
            providerIdentityKeys: accountAssembly.identityKeysByCard,
            familyTotalHistoryCardIDs: accountAssembly.familyTotalHistoryCardIDs,
            resolveDisplayName: { [accounts] in accounts.resolvedDisplayName(cardID: $0) }
        )
        let resetWatchCoordinator = CodexResetWatchCoordinator(
            publish: { [dataStore] in dataStore.setCodexResetWatch($0) }
        )
        let iCloudSync = ICloudUsageSyncStore(dataStore: dataStore)
        // provider 재활성화 시 즉시 fetch되도록 잔여 failure backoff 제거. `weak`로 순환 참조 차단 (dataStore가 이미 enablement 캡처).
        enablement.onProviderEnabled = { [weak dataStore] id in dataStore?.clearFailureBackoff(for: id) }
        enablement.onChange = { [weak dataStore, weak iCloudSync] in
            dataStore?.providerEnablementDidChange()
            iCloudSync?.scheduleWrite()
        }
        // 신규 설치는 최소 구성으로 시작 — enabled-provider 목록 seed. 이후 런치에서는 no-op.
        let onboarding = OnboardingStore()
        self.seedTask = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: isFreshInstall,
            providers: providers,
            enablement: enablement,
            onboarding: onboarding
        )
        // 업데이트로 추가된 provider도 첫 런치에 동일한 credential 탐지 적용. 처음 보는 provider가 없으면 no-op.
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
        self.resetWatchCoordinator = resetWatchCoordinator

        // Codex 카드별 claim service — 각 카드의 credential 로딩·HTTP client 공유로 claim auth가 카드와 불일치 불가.
        // claim 성공 시 해당 카드 강제 refresh — in-flight refresh는 pre-claim 사용량일 수 있어 실제 실행까지 재시도 (bounded).
        let codexProviders = providers.compactMap { $0 as? CodexProvider }
        self.codexResetClaim = CodexResetClaimRouter(
            providers: codexProviders,
            refreshAfterClaim: { [weak dataStore] providerID in
                // 재시도 한도는 provider의 최장 refresh(≈45s)보다 길게 유지 필수 — pre-claim meter 위에 성공 배너 방지.
                // `.failed`도 수 회 재시도 후 loud하게 포기 (provider 오류가 카드에 표시되므로 staleness 비은폐).
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

        // 익명 opt-in telemetry. 상태는 전용 UserDefaults suite에 격리 — 공유 선택과 install id가 앱 설정 변경과 독립.
        let telemetryStore = TelemetryStore()
        let telemetry = TelemetryRecorder(
            sink: PostHogTelemetrySink(enabled: telemetryStore.enabled),
            store: telemetryStore,
            snapshot: { [enablement, layout, dataStore] in
                // 활성 구성만 보고 — 꺼진 provider의 metric 제외로 `enabledProviders`와 일관 유지.
                let providerOn: (String) -> Bool = { metricID in
                    guard let providerID = layout.registry.descriptor(id: metricID)?.providerID else { return false }
                    return enablement.isEnabled(providerID)
                }
                return TelemetryConfigSnapshot.collapsingAccountCards(
                    enabledProviders: dataStore.knownProviderIDs.filter { enablement.isEnabled($0) },
                    enabledMetricIDs: layout.placed.map(\.descriptorID).filter(providerOn),
                    pinnedMetricIDs: layout.pinnedMetricIDs.filter(providerOn),
                    expandedMetricIDs: layout.expandedMetricIDs.filter(providerOn),
                    menuBarStyle: layout.menuBarStyle.rawValue,
                    providerIDForMetric: { layout.registry.descriptor(id: $0)?.providerID }
                )
            }
        )
        dataStore.onRefreshOutcome = { [weak telemetry] providerID, outcome, category, manual in
            telemetry?.record(providerID: providerID, outcome: outcome, category: category, manual: manual)
        }
        self.telemetry = telemetry
        self.transparency = PopoverTransparencyStore()
        self.privacy = MenuBarPrivacyStore()
        self.localAPI = LocalUsageServer(state: { [layout, enablement, dataStore] in
            LocalUsageAPI.State(
                enabledOrderedIDs: layout.orderedProviderIDs().filter { enablement.isEnabled($0) },
                knownIDs: Set(dataStore.knownProviderIDs),
                snapshots: dataStore.snapshots,
                limitDescriptors: dataStore.limitDescriptorsByProvider,
                errors: dataStore.providerErrors
            )
        })
        observeResetWatchActivity()
        self.refreshTask.task = Self.startPeriodicRefresh(
            dataStore: dataStore,
            telemetry: telemetry,
            reconcileAccounts: { [weak self] in
                _ = await self?.reconcileExternalClaudeAuthenticationAndRefreshCatalog()
            }
        )
        localAPI.start()
        // notification-center delegate 등록 — frontmost 상태에서도 배너 표시. 권한 요청은 런치가 아니라 Settings의 트리거 첫 활성화 시.
        AppNotifications.shared.registerAsDelegate()
    }

    deinit {
        seedTask?.cancel()
        newProviderTask?.cancel()
        shellEnvironmentSnapshotTask.cancel()
    }

    /// 카드가 렌더링되는 제목 — Claude·Codex는 계정과 무관하게 provider 이름 고정(`ProviderAccountID.cardTitle`).
    /// 그 외 provider는 account registry 이름, 없으면 정적 display name.
    func displayName(for provider: Provider) -> String {
        ProviderAccountID.cardTitle(
            providerID: provider.id,
            fallback: accounts.resolvedDisplayName(cardID: provider.id) ?? provider.displayName
        )
    }

    /// 관리형 profile 기반 카드의 profile label; 아니면 `nil`.
    func accountProfileLabel(for cardID: String) -> String? {
        guard let profileID = accountProfileIDsByCardID[cardID] else { return nil }
        return accountProfiles.profile(id: profileID)?.label
    }

    /// family의 현재 선택된 관리형 profile이 backing하는 표시 카드.
    func preferredAccountCardID(for family: String, among cardIDs: [String]) -> String? {
        guard let profileID = accountProfiles.preferredProfileID(family: family) else { return nil }
        return cardIDs.first { accountProfileIDsByCardID[$0] == profileID }
    }

    /// family가 지금 렌더하는 카드 — 저장된 dashboard 선택 → 선택 profile 카드 → 공유 runtime → 첫 카드.
    func visibleAccountCardID(for family: String, among cardIDs: [String], stored: String) -> String? {
        guard let first = cardIDs.first else { return nil }
        if cardIDs.contains(stored) { return stored }
        if let preferred = preferredAccountCardID(for: family, among: cardIDs) { return preferred }
        return cardIDs.contains(family) ? family : first
    }

    /// family에 속한 카드 id — 등록 계정과 독립 발견 로그인을 구분하지 않음(모두 한 카드의 계정 선택지).
    func accountCardIDs(for family: String, among orderedIDs: [String]) -> [String] {
        orderedIDs.filter { ProviderAccountID.family(of: $0) == family }
    }

    /// dashboard 계정 선택이 바뀔 때마다 증가 — 선택은 `UserDefaults`에 저장돼 관찰되지 않으므로,
    /// 메뉴 바 strip이 이 값을 읽어 refresh 성패와 무관하게 선택 계정으로 다시 그림.
    private(set) var accountSelectionRevision = 0

    func noteAccountSelectionChanged() {
        accountSelectionRevision &+= 1
    }

    /// dashboard와 메뉴 바가 공유하는 표시 카드 필터 — provider당 카드 1장, 나머지 계정은 header selector로.
    /// layout 설정도 family 단위 1벌이라 축약하지 않으면 같은 행이 카드 수만큼 중복 렌더됨.
    func collapsingAccountCards(_ orderedIDs: [String], selectionByFamily: [String: String]) -> [String] {
        var visible = orderedIDs
        for family in AccountProfilesStore.supportedFamilies {
            let cards = accountCardIDs(for: family, among: orderedIDs)
            guard cards.count > 1 else { continue }
            visible = DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: visible,
                familyCardIDs: Set(cards),
                selectedCardID: visibleAccountCardID(
                    for: family,
                    among: cards,
                    stored: selectionByFamily[family] ?? ""
                )
            )
        }
        return visible
    }

    /// 계정 selector에 표시할 이름 — 규칙은 `DashboardUsageAccountSelection.optionTitle`.
    func accountOptionTitle(for cardID: String) -> String {
        DashboardUsageAccountSelection.optionTitle(
            cardID: cardID,
            profileLabel: accountProfileLabel(for: cardID),
            accountName: accounts.resolvedDisplayName(cardID: cardID)
        )
    }

    /// Settings 계정 전환 성공 시 dashboard selector를 1회 갱신.
    /// 메뉴 바 star는 family 설정이라 재지정 불필요 — 표시 값만 선택 카드를 따라감.
    /// 이후 dashboard picker 변경은 view 전용 — terminal 전환 없음.
    func syncDashboardUsageAccount(to profile: AccountProfile) {
        guard let cardID = DashboardUsageAccountSelection.selectAfterAccountSwitch(
            family: profile.family,
            availableCardIDs: registry.providers.map(\.id)
        ) else {
            return
        }
        noteAccountSelectionChanged()
        Task { await dataStore.refreshAfterAccountSelection(providerID: cardID) }
    }

    /// Settings의 관리형 profile 변경 직후 account 카드 추가/제거 반영.
    /// root store는 유지 — 열린 dashboard와 status item이 재시작 없이 새 registry 사용.
    func refreshAccountCatalog() {
        let assembly = ProviderAccountAssembly.make(
            accountsStore: accounts,
            waitsForLoginShell: true,
            accountProfiles: accountProfiles
        )
        guard assembly != accountAssembly else { return }
        accountAssembly = assembly
        let nextProviders = ProviderCatalog.make(
            hasUnregisteredClaudeLogins: assembly.hasUnregisteredClaudeLogins,
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

    /// 사용자 새로 고침 — shared-home 재인증과 catalog binding을 먼저 반영한 뒤 usage 조회.
    func refreshAll(force: Bool = false) async {
        let reconciliationError = await reconcileExternalClaudeAuthenticationAndRefreshCatalog()
        await dataStore.refreshAll(force: force)
        if let reconciliationError {
            dataStore.setExternalProviderError(reconciliationError, for: "claude")
        }
    }

    /// 단일 카드 사용자 새로 고침 — Claude managed binding을 먼저 반영.
    func refresh(providerID: String, force: Bool = false) async -> WidgetDataStore.RefreshOutcome {
        var reconciliationError: String?
        if ProviderAccountID.family(of: providerID) == "claude" {
            reconciliationError = await reconcileExternalClaudeAuthenticationAndRefreshCatalog()
        }
        let outcome = await dataStore.refresh(providerID: providerID, force: force)
        if let reconciliationError {
            dataStore.setExternalProviderError(reconciliationError, for: "claude")
        }
        return outcome
    }

    /// 배치·pin·provider enablement의 최종 활성 상태를 관찰해 독립 Reset Watch task에 전달.
    private func observeResetWatchActivity() {
        let active = withObservationTracking {
            layout.orderedRefreshDescriptors().contains {
                ProviderAccountID.canonicalMetricID($0.id) == "codex.resetWatch"
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeResetWatchActivity()
            }
        }
        resetWatchCoordinator.setActive(active)
    }

    @discardableResult
    private func reconcileExternalClaudeAuthentication() async -> Result<Bool, Error> {
        guard !isReconcilingExternalClaudeAuthentication else { return .success(false) }
        isReconcilingExternalClaudeAuthentication = true
        defer { isReconcilingExternalClaudeAuthentication = false }
        do {
            switch try await AccountCredentialImporter()
                .reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: accountProfiles) {
            case .updated(let profileID):
                AppLog.info(.auth, "external Claude reauthentication updated selected profile (\(profileID.prefix(8))…)")
                return .success(true)
            case .unchanged, .noUsableAuthentication:
                return .success(false)
            }
        } catch {
            AppLog.error(.auth, "external Claude reauthentication reconciliation failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// 외부 Claude 로그인 반영 — 실패 시 log와 함께 수동 refresh가 카드에 표시할 친화적 메시지 반환.
    @discardableResult
    func reconcileExternalClaudeAuthenticationAndRefreshCatalog() async -> String? {
        switch await reconcileExternalClaudeAuthentication() {
        case .success(true):
            refreshAccountCatalog()
            return nil
        case .success(false):
            return nil
        case .failure:
            return "OpenUsage couldn't update the selected Claude sign-in. The saved account was left unchanged. Check the app log and try again."
        }
    }

    /// account runtime은 한 provider의 대체 view — Customize 마스터 토글은 family 전체 카드를 함께 on/off.
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

    /// Customize "Reset All"의 enablement 절반 — 첫 런치 credential 탐지 재실행.
    /// `FirstRunSeeder.reseed`에 위임; await 가능한 탐지 task 반환.
    @discardableResult
    func reseedEnabledProviders() -> Task<Void, Never> {
        FirstRunSeeder.reseed(providers: providers, enablement: enablement)
    }

    static func accountProfileIDsByCardID(
        assembly: ProviderAccountAssembly,
        profiles: AccountProfilesStore
    ) -> [String: String] {
        // 선택 profile은 bare family 카드, 비활성 profile은 명시적인 snapshot 카드만 담당.
        var result = assembly.profileIDsByCard
        for family in AccountProfilesStore.supportedFamilies {
            guard let selected = profiles.preferredProfile(family: family) else { continue }
            if let observed = assembly.identityKeysByCard[family], observed != selected.identityKey {
                // 공유 home이 외부에서 다른 계정으로 로그인된 경우 — bare 카드가 그 로그인을 표시하므로 선택 profile의 label 미점유.
                continue
            }
            result[family] = selected.id
        }
        return result
    }

    /// 주기 refresh loop: 런치 직후 1회, 이후 매 interval 실행. 각 패스는 cache 준수 — 만료된 snapshot만 네트워크 요청.
    /// 패스 사이 대기는 `RefreshWakeSignal` 경유 — 첫 패스 전 구독·buffer로 패스 도중의 enablement 변경도 무유실.
    /// wake는 `ProviderEnablementStore.didChangeNotification` 한정 필수 — `UserDefaults.didChangeNotification` 구독은 refresh 폭주 유발.
    private static func startPeriodicRefresh(
        dataStore: WidgetDataStore,
        telemetry: TelemetryRecorder,
        reconcileAccounts: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        Task {
            let wakeSignal = RefreshWakeSignal()
            while !Task.isCancelled {
                await reconcileAccounts()
                await dataStore.refreshAll()
                // 매 tick 알림 재평가 — refresh 후 실행으로 최신 데이터 참조, fetch 없는 loop에서도 시간 경과 pace 악화 감지.
                await dataStore.evaluateNotifications()
                // 일자 전환 beat: `app_daily_active` 1일 1회 발행 + 전일 provider rollup flush.
                telemetry.tick()
                await wakeSignal.waitForWake(timeout: RefreshSetting.interval)
            }
        }
    }
}
