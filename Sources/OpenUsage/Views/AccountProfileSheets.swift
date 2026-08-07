import SwiftUI

/// The Add Account flow. Pressing **Add Account** is the consent to start: with a signed-in
/// default and no registered profile the current login is imported without any re-login; otherwise
/// the official provider login runs — in the profile's app-owned Sign-In Workspace for an
/// additional account, or against the Shared Runtime Home for the very first one. No paths, no
/// copyable commands, no verification step.
struct AccountAddSheet: View {
    let initialFamily: String
    let onCompleted: () -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var family: String
    @State private var phase: Phase = .idle
    @State private var signInTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle
        case signingIn
        case failed(String)
    }

    init(initialFamily: String, onCompleted: @escaping () -> Void) {
        self.initialFamily = initialFamily
        self.onCompleted = onCompleted
        _family = State(initialValue: initialFamily)
    }

    private var store: AccountProfilesStore { container.accountProfiles }

    private var familyTitle: String {
        family == "claude" ? "Claude" : "Codex"
    }

    private var isFirstAccount: Bool {
        store.profiles(family: family).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add \(familyTitle) Account")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button("Cancel") {
                    signInTask?.cancel()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            Picker("Provider", selection: $family) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }
            .pickerStyle(.segmented)
            .disabled(phase == .signingIn)

            Text(
                isFirstAccount
                    ? "If you're already signed in, OpenUsage imports that account without another login. Otherwise the official \(familyTitle) sign-in opens in your browser."
                    : "The official \(familyTitle) sign-in opens in your browser. Your current account and terminal sessions stay unchanged."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            switch phase {
            case .idle:
                EmptyView()
            case .signingIn:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for the \(familyTitle) sign-in to finish…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer(minLength: 0)
                Button(phase == .signingIn ? "Signing In…" : "Add Account") {
                    addAccount()
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.small)
                .disabled(phase == .signingIn)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onChange(of: family) {
            phase = .idle
        }
        .onDisappear {
            signInTask?.cancel()
        }
    }

    private func addAccount() {
        phase = .signingIn
        let family = family
        let importer = AccountCredentialImporter()

        // A signed-in default with no registered profile imports directly — no re-login.
        if isFirstAccount {
            do {
                if let profile = try importer.importDefaultAccount(family: family, into: store) {
                    AppLog.info(.config, "accounts: imported the signed-in default \(family) account (\(profile.id.prefix(8))…)")
                    finish()
                    return
                }
            } catch {
                fail(error)
                return
            }
        }

        // No current login (first account) → official login into the Shared Runtime Home.
        // Additional account → official login scoped to a fresh Sign-In Workspace.
        let profileID = isFirstAccount ? nil : UUID().uuidString
        signInTask = Task {
            do {
                let workspace = AccountSignInWorkspace()
                let home: String
                if let profileID {
                    home = try workspace.prepare(family: family, profileID: profileID).path
                } else {
                    home = AccountShellInstaller.sharedConfigurationHome(
                        family: family,
                        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                    )
                }
                let code = try await AccountSignInLauncher().runLogin(family: family, home: home)
                guard !Task.isCancelled else {
                    if let profileID { try? importer.removeSignInWorkspace(family: family, profileID: profileID) }
                    return
                }
                guard code == 0 else {
                    if let profileID { try? importer.removeSignInWorkspace(family: family, profileID: profileID) }
                    phase = .failed("The \(familyTitle) sign-in did not complete. Nothing was added — try again.")
                    return
                }
                if let profileID {
                    guard let credential = try importer.readWorkspaceCredential(family: family, profileID: profileID) else {
                        try? importer.removeSignInWorkspace(family: family, profileID: profileID)
                        phase = .failed("The \(familyTitle) sign-in finished without a usable credential. Nothing was added.")
                        return
                    }
                    // The new profile is registered but NOT selected: switching stays an explicit
                    // toggle so an add can never silently change what new terminals use.
                    _ = try importer.register(
                        credential,
                        family: family,
                        label: credential.label ?? "Account",
                        id: profileID,
                        into: store
                    )
                } else {
                    guard try importer.importDefaultAccount(family: family, into: store) != nil else {
                        phase = .failed("The \(familyTitle) sign-in finished without a usable credential. Nothing was added.")
                        return
                    }
                }
                finish()
            } catch is CancellationError {
                if let profileID {
                    try? importer.removeSignInWorkspace(family: family, profileID: profileID)
                }
            } catch {
                if let profileID {
                    try? importer.removeSignInWorkspace(family: family, profileID: profileID)
                }
                fail(error)
            }
        }
    }

    private func finish() {
        onCompleted()
        dismiss()
    }

    private func fail(_ error: any Error) {
        if let error = error as? AccountProfileError {
            phase = .failed(error.userMessage)
        } else {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// The Manage sheet for one registered account: rename, re-run the official sign-in in the
/// profile's own workspace, or remove. Only the Account Name is editable — provider, identity, and
/// storage stay internal.
struct AccountProfileManagementSheet: View {
    let profile: AccountProfile
    let signInState: AccountSignInProbe.State
    let onChanged: () -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var profileLabel: String
    @State private var renameError: String?
    @State private var actionError: String?
    @State private var isSigningIn = false
    @State private var signInTask: Task<Void, Never>?
    @State private var isRemoveConfirmationPresented = false

    init(
        profile: AccountProfile,
        signInState: AccountSignInProbe.State,
        onChanged: @escaping () -> Void
    ) {
        self.profile = profile
        self.signInState = signInState
        self.onChanged = onChanged
        _profileLabel = State(initialValue: profile.label)
    }

    private var store: AccountProfilesStore { container.accountProfiles }

    private var familyTitle: String {
        profile.family == "claude" ? "Claude" : "Codex"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Manage \(familyTitle) Account")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button("Done") {
                    save()
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Account Name")
                    .font(.callout.weight(.semibold))
                TextField("Account Name", text: $profileLabel)
                    .textFieldStyle(.roundedBorder)
                if let renameError {
                    Text(renameError)
                        .font(.caption2)
                        .foregroundStyle(Theme.notice)
                }
            }

            HStack(spacing: 8) {
                AccountStatusBadge(state: signInState)
                Spacer(minLength: 8)
                Button(isSigningIn ? "Signing In…" : "Sign In Again") {
                    signInAgain()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isSigningIn)
            }

            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer(minLength: 8)
                Button("Remove Account", role: .destructive) {
                    isRemoveConfirmationPresented = true
                }
                .buttonStyle(.borderless)
                .disabled(isSigningIn)
            }
        }
        .padding(22)
        .frame(width: 360)
        .alert(
            "Remove \(profile.label)?",
            isPresented: $isRemoveConfirmationPresented
        ) {
            Button("Remove Account", role: .destructive) {
                removeAccount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenUsage deletes its saved Keychain authentication and sign-in workspace for this account. Your Claude and Codex settings, sessions, and the current terminal login stay in place.")
        }
        .onDisappear {
            signInTask?.cancel()
        }
    }

    private func save() {
        do {
            try store.rename(profileID: profile.id, to: profileLabel)
            onChanged()
            dismiss()
        } catch let error as AccountProfileError {
            renameError = error.userMessage
        } catch {
            renameError = error.localizedDescription
        }
    }

    /// Official re-login in this profile's own Sign-In Workspace. The snapshot is replaced only
    /// when the fresh credential proves the SAME account; a different identity changes nothing and
    /// asks for a separate Add instead. Re-signing the active profile also refreshes the Shared
    /// Runtime Home so new terminals pick the new credential up immediately.
    private func signInAgain() {
        isSigningIn = true
        actionError = nil
        signInTask = Task {
            defer { isSigningIn = false }
            do {
                let workspace = AccountSignInWorkspace()
                let home = try workspace.prepare(family: profile.family, profileID: profile.id).path
                let launcher = AccountSignInLauncher()
                let code = try await launcher.runLogin(family: profile.family, home: home)
                guard !Task.isCancelled else { return }
                guard code == 0 else {
                    actionError = "The \(familyTitle) sign-in did not complete. The saved account is unchanged."
                    return
                }
                try AccountCredentialImporter().completeReSignIn(
                    for: profile,
                    isActive: store.preferredProfileID(family: profile.family) == profile.id
                )
                onChanged()
            } catch is CancellationError {
                // Cancelled sheet close — nothing was changed.
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Removal order is fixed: app-owned workspace first, then Keychain snapshot, then the registry
    /// tombstone. A failure at any step keeps the profile registered for a retry, and the shared
    /// homes are never touched.
    private func removeAccount() {
        // The selected profile can't be removed while another profile exists — switch first, so a
        // switchable family never loses the row that answers for its active authentication.
        if store.preferredProfileID(family: profile.family) == profile.id,
           store.profiles(family: profile.family).count > 1 {
            actionError = AccountProfileError.removeSelectedProfile.userMessage
            return
        }
        do {
            try AccountCredentialImporter().removeAccount(profile, from: store)
        } catch let error as AccountProfileError {
            actionError = error.userMessage
            return
        } catch {
            AppLog.warn(.config, "account profile removal failed: \(error.localizedDescription)")
            actionError = error.localizedDescription
            return
        }
        onChanged()
        dismiss()
    }
}
