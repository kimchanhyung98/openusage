import SwiftUI

/// 관리되는 Claude/Codex 계정의 Settings surface — family별 토글은 하나의 Shared Runtime Home을 유지한 채
/// authentication만 선택 계정으로 교체. 행은 credential/경로를 노출하지 않음 — badge는 저장된 sign-in의
/// 유효성에 대한 로컬 `AccountSignInProbe` 판정.
struct AccountsSettingsSection: View {
    @Environment(AppContainer.self) private var container
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let scrollViewportFrame: CGRect
    let scrollToAccount: (String, AccountSettingsReorderDirection) -> Void

    @State private var isAddSheetPresented = false
    @State private var addFamily = "claude"
    @State private var editingProfile: AccountProfile?
    @State private var signInStates: [String: AccountSignInProbe.State] = [:]
    @State private var pendingSelection: AccountProfile?
    @State private var isSwitchConfirmationPresented = false
    @State private var switchError: String?

    private var store: AccountProfilesStore { container.accountProfiles }

    private struct FamilyInfo: Identifiable {
        let id: String
        let title: String
    }

    private static let families: [FamilyInfo] = [
        FamilyInfo(id: "claude", title: "Claude"),
        FamilyInfo(id: "codex", title: "Codex"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            HStack(spacing: 5) {
                Text("Accounts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Button {
                    addFamily = "claude"
                    isAddSheetPresented = true
                } label: {
                    Image(systemName: "plus.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Account")
                .disabled(store.hasUnreadableRegistry)
            }
            .padding(.horizontal, 8)

            VStack(spacing: density.sectionSpacing) {
                let populatedFamilies = Self.families.filter { !store.profiles(family: $0.id).isEmpty }
                if store.hasUnreadableRegistry {
                    Text(AccountProfileError.registryUnreadable.userMessage)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(Theme.notice)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, density.controlRowPadding)
                } else if populatedFamilies.isEmpty {
                    Text("Add a Claude or Codex account to switch which sign-in new terminal sessions use.")
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, density.controlRowPadding)
                } else {
                    if container.accountCardPresentation.shouldShowDisplayMode(
                        profiles: store.profiles,
                        registryReadable: !store.hasUnreadableRegistry
                    ) {
                        usageCardsRow
                    }
                    ForEach(populatedFamilies, id: \.id) { family in
                        familyCard(family: family.id, title: family.title)
                    }
                }
            }
            .cardSurface()

            if let switchError {
                Text(switchError)
                    .font(.caption2)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 8)
            }
            if let presentationError = container.accountCardPresentation.errorMessage {
                Text(presentationError)
                    .font(.caption2)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 8)
            }
        }
        .sheet(isPresented: $isAddSheetPresented) {
            AccountAddSheet(initialFamily: addFamily) {
                container.refreshAccountCatalog()
                refreshSignInStates()
            }
        }
        .sheet(item: $editingProfile) { profile in
            AccountProfileManagementSheet(
                profile: profile,
                signInState: signInStates[profile.id] ?? .needsSignIn
            ) {
                container.refreshAccountCatalog()
                refreshSignInStates()
            }
        }
        .confirmationDialog(
            "Switch Account?",
            isPresented: $isSwitchConfirmationPresented,
            titleVisibility: .visible,
            presenting: pendingSelection
        ) { profile in
            Button("Switch Account") {
                switchTo(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            if let shell = AccountShellInstaller.defaultShell() {
                Text("New `\(profile.family)` sessions will use \(profile.label). OpenUsage keeps your settings, memory, and sessions in place, replaces only the saved sign-in, and updates the \(shell.title) terminal setup. Open a new terminal window to use it.")
            } else {
                Text("OpenUsage couldn't detect your login shell, so terminal setup can't be applied automatically.")
            }
        }
        .onAppear {
            // 다른 창이 같은 defaults domain을 갱신한 뒤 재오픈될 수 있어 reload.
            store.reloadFromDefaults()
            container.refreshAccountCatalog()
            refreshSignInStates()
            Task {
                _ = await container.reconcileExternalClaudeAuthenticationAndRefreshCatalog()
                refreshSignInStates()
            }
        }
        .onChange(of: store.profiles) {
            refreshSignInStates()
        }
        .onChange(of: store.authenticationRevision) {
            refreshSignInStates()
        }
    }

    // MARK: - Family card

    private var usageCardsRow: some View {
        HStack(spacing: 10) {
            Text("Usage Cards")
            Spacer(minLength: 8)
            Picker("Usage Cards", selection: accountCardModeBinding) {
                ForEach(AccountCardDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private var accountCardModeBinding: Binding<AccountCardDisplayMode> {
        Binding(
            get: { container.accountCardPresentation.mode },
            set: { container.accountCardPresentation.setMode($0) }
        )
    }

    private func familyCard(family: String, title: String) -> some View {
        AccountSettingsFamilyCard(
            family: family,
            title: title,
            signInStates: signInStates,
            reorderSpaceName: reorderSpaceName,
            reorderLift: $reorderLift,
            scrollViewportFrame: scrollViewportFrame,
            scrollToAccount: scrollToAccount,
            onManage: { editingProfile = $0 },
            selection: { selectionBinding(family: family, profileID: $0) }
        )
    }

    /// family별 선택의 radio 동작 — 다른 profile 선택은 이동, 선택된 스위치 off는 무시:
    /// Ready profile이 있는 family가 전원 해제 상태로 남지 않음.
    private func selectionBinding(family: String, profileID: String) -> Binding<Bool> {
        Binding(
            get: { store.preferredProfileID(family: family) == profileID },
            set: { isSelected in
                guard isSelected,
                      let profile = store.profiles.first(where: { $0.id == profileID && $0.family == family })
                else {
                    return
                }
                pendingSelection = profile
                isSwitchConfirmationPresented = true
            }
        )
    }

    private func switchTo(_ profile: AccountProfile) {
        guard let shell = AccountShellInstaller.defaultShell() else {
            switchError = "Couldn't detect your login shell, so OpenUsage couldn't apply the account switch automatically."
            return
        }
        let currentProfile = store.preferredProfile(family: profile.family)
        do {
            // wrapper는 계정 무관(shared home만 고정)이므로 먼저 설치 — 실패해도 아무것도 전환되지 않고,
            // auth transaction commit 이후에는 shared home과 선택 상태 사이에 실패 가능한 단계 없음.
            try AccountShellInstaller.install(family: profile.family, shell: shell)
            try AccountCredentialSwitcher().switchAuthentication(to: profile, from: currentProfile)
            store.setPreferred(family: profile.family, profileID: profile.id)
            container.refreshAccountCatalog()
            container.syncDashboardUsageAccount(to: profile)
            switchError = nil
        } catch {
            switchError = "Couldn't switch to \(profile.label): \(error.localizedDescription)"
        }
    }

    // MARK: - Sign-in probe

    private func refreshSignInStates() {
        let probe = AccountSignInProbe()
        var states: [String: AccountSignInProbe.State] = [:]
        for profile in store.profiles where !profile.isArchived {
            states[profile.id] = probe.state(
                for: profile,
                isSelected: store.preferredProfileID(family: profile.family) == profile.id
            )
        }
        signInStates = states
    }
}

/// 계정 행/sheet의 compact readiness dot — 저장된 sign-in이 유효하면 green, sign-in 필요하면 amber.
struct AccountStatusBadge: View {
    let state: AccountSignInProbe.State

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.isReady ? Theme.positive : Theme.notice)
                .frame(width: 5, height: 5)
            Text(state.isReady ? "Ready" : "Sign-In Needed")
                .font(.caption2.weight(.medium))
                .foregroundStyle(state.isReady ? Theme.positive : Theme.notice)
                .lineLimit(1)
        }
    }
}

extension AccountSignInProbe.State {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}
