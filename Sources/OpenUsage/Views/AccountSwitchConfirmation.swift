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
    @State private var switchTask: Task<Void, Never>?
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
                "Switch Account?",
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: selection
            ) { profile in
                Button("Use \(profile.family.capitalized): \(profile.label)") {
                    switchTo(profile)
                }
                .disabled(switchTask != nil || store.isAuthenticationMutationInProgress)
                Button("Cancel", role: .cancel) {}
            } message: { profile in
                if let shell = AccountShellInstaller.defaultShell() {
                    Text("New `\(profile.family)` sessions will use \(profile.label). OpenUsage keeps your settings, memory, and sessions in place, replaces only the saved sign-in, and updates the \(shell.title) terminal setup. Open a new terminal window to use it.")
                } else {
                    Text("OpenUsage couldn't detect your login shell, so terminal setup can't be applied automatically.")
                }
            }
            .onDisappear { switchTask?.cancel() }
    }

    private func switchTo(_ profile: AccountProfile) {
        guard switchTask == nil, !store.isAuthenticationMutationInProgress else { return }
        let status = container.accountStatus(for: profile, localState: localStates[profile.id])
        guard status.canSwitch else {
            error = status.message ?? "Sign in again before switching to this account."
            let category: ErrorCategory = if case .sessionExpired = status { .authExpired } else { .notLoggedIn }
            AppDiagnostics.record(.accountSwitch, result: .failure, category: category, providerID: profile.family,
                                  localContext: "Account switch requires sign-in; account switch not applied")
            return
        }
        guard let shell = AccountShellInstaller.defaultShell() else {
            error = "Couldn't detect your login shell, so OpenUsage couldn't apply the account switch automatically."
            AppDiagnostics.record(.accountSwitch, result: .failure, category: .notAvailable, providerID: profile.family,
                                  localContext: "Login shell could not be detected; account switch not applied")
            return
        }
        switchTask = Task {
            defer { switchTask = nil }
            do {
                try Task.checkCancellation()
                guard !store.isAuthenticationMutationInProgress else { throw AccountAuthenticationMutationError.busy }
                // 계정과 무관한 wrapper 설치를 인증 적용보다 먼저 완료.
                try AccountShellInstaller.install(family: profile.family, shell: shell)
                try await AccountCredentialSwitcher().switchAuthentication(to: profile, in: store)
                container.refreshAccountCatalog()
                container.syncDashboardUsageAccount(to: store.profile(id: profile.id) ?? profile)
                error = nil
                AppDiagnostics.record(.accountSwitch, result: .success, providerID: profile.family)
            } catch is CancellationError {
                AppDiagnostics.record(.accountSwitch, result: .cancelled, providerID: profile.family)
            } catch let switchError {
                AppDiagnostics.failure(.accountSwitch, error: switchError, providerID: profile.family)
                error = "Couldn't switch to \(profile.label): \(switchError.localizedDescription)"
            }
        }
    }
}
