import SwiftUI

extension View {
    func accountSwitchConfirmation(
        selection: Binding<AccountProfile?>,
        error: Binding<String?>,
        localStates: [String: AccountSignInProbe.State] = [:]
    ) -> some View {
        modifier(AccountSwitchConfirmation(selection: selection, error: error, localStates: localStates))
    }
}

private struct AccountSwitchConfirmation: ViewModifier {
    @Environment(AppContainer.self) private var container
    @Binding var selection: AccountProfile?
    @Binding var error: String?
    let localStates: [String: AccountSignInProbe.State]

    private var store: AccountProfilesStore { container.accountProfiles }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { if !$0 { selection = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.accounts("Switch Account?"),
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: selection
            ) { profile in
                Button(L10n.accounts("Use %@: %@", profile.family.capitalized, profile.label)) {
                    switchTo(profile)
                }
                .disabled(container.accountSwitch.isSwitching)
                Button(L10n.accounts("Cancel"), role: .cancel) {}
            } message: { profile in
                if let shell = AccountShellInstaller.defaultShell() {
                    Text(L10n.accounts(
                        "New %@ sessions will use %@. OpenUsage keeps your settings, memory, and sessions in place, replaces only the saved sign-in, and updates the %@ terminal setup. Open a new terminal window to use it.",
                        profile.family, profile.label, shell.title
                    ))
                } else {
                    Text(L10n.accounts("OpenUsage couldn't detect your login shell, so terminal setup can't be applied automatically."))
                }
            }
    }

    private func switchTo(_ profile: AccountProfile) {
        guard !container.accountSwitch.isSwitching else { return }
        guard let shell = AccountShellInstaller.defaultShell() else {
            error = L10n.accounts("Couldn't detect your login shell, so OpenUsage couldn't apply the account switch automatically.")
            AppDiagnostics.record(.accountSwitch, result: .failure, category: .notAvailable, providerID: profile.family,
                                  localContext: "Login shell could not be detected; account switch not applied")
            return
        }
        let providerIDs = AccountSwitchCoordinator.providerIDs(to: profile, from: store.preferredProfile(family: profile.family))
        container.accountSwitch.start(
            profileID: profile.id,
            waitForRefreshes: { await container.waitForAccountSwitchWork(providerIDs: providerIDs) }
        ) {
            let status = container.accountStatus(for: profile, localState: localStates[profile.id])
            guard status.canSwitch else {
                error = status.message ?? L10n.accounts("Sign in again before switching to this account.")
                let category: ErrorCategory = if case .sessionExpired = status { .authExpired } else { .notLoggedIn }
                AppDiagnostics.record(.accountSwitch, result: .failure, category: category, providerID: profile.family,
                                      localContext: "Account switch requires sign-in; account switch not applied")
                return
            }
            let currentProfile = store.preferredProfile(family: profile.family)
            // wrapper는 계정 무관(shared home만 고정)이므로 먼저 설치 — 실패해도 아무것도 전환되지 않고,
            // auth transaction commit 이후에는 shared home과 선택 상태 사이에 실패 가능한 단계 없음.
            try AccountShellInstaller.install(family: profile.family, shell: shell)
            try AccountCredentialSwitcher().switchAuthentication(to: profile, from: currentProfile)
            store.setPreferred(family: profile.family, profileID: profile.id)
            let refreshes = container.refreshAccountCatalog()
            await container.syncDashboardUsageAccount(to: profile)
            for (providerID, refresh) in refreshes where providerIDs.contains(providerID) { await refresh.value }
            error = nil
            AppDiagnostics.record(.accountSwitch, result: .success, providerID: profile.family)
        } onFailure: { switchError in
            AppDiagnostics.failure(.accountSwitch, error: switchError, providerID: profile.family)
            error = L10n.accounts("Couldn't switch to %@: %@", profile.label, UserFacingErrors.message(switchError))
        }
    }
}
