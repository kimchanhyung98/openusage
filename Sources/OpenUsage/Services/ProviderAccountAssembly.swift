import Foundation

/// launch 시점 계정 pass — 기본 home의 로그인 계정 read, custom config dir 스캔,
/// account registry reconcile 후 카드별 identity map 노출.
/// launch(앱)·invocation(CLI)당 1회 실행 — 실행 중 계정 swap은 다음 launch에 반영.
@MainActor
struct ProviderAccountAssembly: Equatable {
    /// 카드 id → 이번 launch에 로그인된 계정 identity — identity 미해석 카드는 부재.
    let identityKeysByCard: [String: String]
    /// family → bare/default 카드를 뒷받침하는 canonical home — identity와 같은 observer 결과에서 도출.
    var defaultHomePathsByFamily: [String: String] = [:]
    /// 공유 home과 다른 계정의 Claude 로그인이 custom config dir에 존재 — 카드는 만들지 않고
    /// Desktop fallback 금지·pi 합산 제외의 gate로만 사용(그 로그인이 남의 usage를 끌어올 수 있으므로).
    var hasUnregisteredClaudeLogins: Bool = false
    /// 기본 카드와 같은 계정으로 판명된 custom config dir — 추가 spend-log root 전용, credential 소스 아님.
    var defaultClaudeExtraLogRoots: [URL] = []
    /// 비활성 managed profile 카드 — credential은 OpenUsage 전용 Keychain snapshot 보관, 대시보드 전용(터미널 redirect 없음).
    var snapshotCards: [AccountUsageSnapshotCard] = []
    /// 로컬 history가 managed shared-home 합산인 bare family 카드 id.
    /// 여러 전환 계정의 세션이 로그를 공유 — history는 family 합계로 sync, 현재 선택 profile identity로 귀속 금지.
    var familyTotalHistoryCardIDs: Set<String> = []
    /// snapshot 카드의 profile 소유 명시 — synthetic provider id는 configuration-home 경로에서 유도 불가.
    var profileIDsByCard: [String: String] = [:]
    /// managed Codex 전환 활성 시 설정되는 shared `~/.codex` home.
    /// 기본 Codex 카드는 이 home의 `auth.json`만 credential 소스로 사용 — stale `Codex Auth` Keychain item의 타 계정 fallback 차단.
    var codexSharedAuthHome: String?
    /// managed Claude profile 존재 시 true — 기본 카드의 Claude Desktop 로그인 fallback 금지.
    /// auth 실패는 re-login으로 표면화 — 타 계정 usage로 표시 금지.
    var claudeManagedSwitchActive: Bool = false

    /// `waitsForLoginShell`: 메뉴바 앱은 true(Finder/Dock launch는 shell export 미상속 → login-shell 레이어 의존), one-shot CLI는 false.
    /// 앱은 UI가 rename을 관찰하는 동일 `accountsStore`(및 `accountProfiles`) 인스턴스 전달, CLI는 생략.
    /// 첫 profile import는 Settings의 명시적 동작 — 이 launch read pass에서 실행 금지.
    static func make(
        defaults: UserDefaults = .standard,
        accountsStore: ProviderAccountsStore? = nil,
        waitsForLoginShell: Bool,
        accountProfiles: AccountProfilesStore? = nil
    ) -> ProviderAccountAssembly {
        // identity read는 provider auth store와 동일한 `ProcessEnvironmentReader` 경유 — identity 키를 세션 내내 snapshot에 고정해 identity와 usage가 같은 home 해석.
        // 첫 Finder/Dock launch(캡처 미완료·snapshot 부재)는 family별 read skip — override 부재로 오독 금지; process 환경에 override가 보이는 family는 해석 유지.
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

        // managed Codex 전환은 provider와 identity read를 shared `~/.codex/auth.json`에 고정 — 파일 실존 시에만 (legacy `~/.config/codex` 전용 로그인은 switch 전까지 기존 소스 목록 유지).
        let sharedCodexAuthFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json").path
        let codexManaged = families.contains("codex")
            && !profileStore.profiles(family: "codex").isEmpty
            && FileManager.default.fileExists(atPath: sharedCodexAuthFile)
        // managed Claude 전환은 `~/.claude`에 identity read 고정 — ambient CLAUDE_CONFIG_DIR로 관리 계정과 관찰 계정이 갈리는 것 방지.
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

    /// family별 기본 home을 재배치하는 환경 변수 — 이 값이 안 보이는 첫 launch에는 해당 family identity read 불가.
    private static let homeOverrideKeys: [String: String] = [
        "claude": "CLAUDE_CONFIG_DIR",
        "codex": "CODEX_HOME",
    ]

    /// 환경 비의존 core — 테스트에서 observer·discovery·store 주입용.
    /// `families`는 home 사실이 읽히는 family로 pass 제한 — 제외된 family는 pass가 없던 것과 동일(identity 키·reconcile 없음).
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
                // 실제 로그인이 계정을 식별 못 하는 빈도 관측용 로그.
                AppLog.info(.config, "accounts: \(family) default identity unresolved — \(reason)")
            case .absent:
                AppLog.debug(.config, "accounts: \(family) has no default login")
            }
        }

        // custom config dir의 추가 Claude 로그인 스캔.
        // 기본 로그인이 `unresolved`면 기본 카드 계정의 중복 카드 렌더 위험 — 이번 launch는 candidate skip; 기본 로그인 부재 시에는 수용 유지.
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
                    if identityKey == defaultKey {
                        // 공유 home과 같은 계정: dir은 그 카드의 추가 spend-log root — 이미 화면에 있는 계정의 로그.
                        defaultClaudeExtraLogRoots += findings.map { URL(fileURLWithPath: $0.anchorPath) }
                        if let index = observations.firstIndex(where: { $0.family == "claude" && $0.identityKey == identityKey }) {
                            observations[index].sources += findings.map {
                                ProviderAccountSource(
                                    kind: .configDir,
                                    anchor: $0.anchorPath,
                                    holdsDefaultSource: false,
                                    keychainLiteral: $0.keychainLiteral
                                )
                            }
                        }
                        AppLog.info(.config, "discovery: \(findings.count) config dir(s) fold onto the default claude card (same account)")
                    } else {
                        // 등록하지 않은 계정 — 카드도 record도 만들지 않음. Settings 등록이 노출의 유일한 경로.
                        foundClaudeAccounts.append((identityKey, findings.first?.label, findings))
                        AppLog.info(.config, "discovery: config-dir login \(ProviderAccountID.make(family: "claude", identityKey: identityKey)) is not registered → not shown")
                    }
                }
            }
        }

        _ = accountsStore.reconcile(with: observations)

        // 비활성 managed profile은 Keychain snapshot 기반 snapshot 카드로 렌더 — home-backed 카드로 이미 보이는 계정은 중복 생성 금지.
        let preferredProfileIDs = Dictionary(uniqueKeysWithValues: ProviderAccountID.families.compactMap { family in
            accountProfiles?.preferredProfileID(family: family).map { (family, $0) }
        })
        let snapshotCards = AccountUsageCardPlanner.snapshotCards(
            profiles: managedProfiles,
            preferredProfileIDs: preferredProfileIDs,
            availableSnapshotProfileIDs: snapshotProfileIDs,
            sharedHomeIdentityKeys: identityKeys
        )
        let profileIDsByCard = Dictionary(uniqueKeysWithValues: snapshotCards.map { ($0.id, $0.profileID) })
        for card in snapshotCards {
            if let profile = managedProfiles.first(where: { $0.id == card.profileID }) {
                identityKeys[card.id] = profile.identityKey
            }
        }

        return ProviderAccountAssembly(
            identityKeysByCard: identityKeys,
            defaultHomePathsByFamily: defaultHomePaths,
            hasUnregisteredClaudeLogins: !foundClaudeAccounts.isEmpty,
            defaultClaudeExtraLogRoots: defaultClaudeExtraLogRoots,
            snapshotCards: snapshotCards,
            familyTotalHistoryCardIDs: Set(managedProfiles.filter { !$0.isArchived }.map(\.family)),
            profileIDsByCard: profileIDsByCard,
            codexSharedAuthHome: codexSharedAuthHome,
            claudeManagedSwitchActive: claudeManagedSwitchActive
        )
    }
}
