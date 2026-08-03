import AppKit
import SwiftUI

struct AccountStatusBadge: View {
    let status: String
    let isHealthy: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isHealthy ? Theme.positive : Theme.notice)
                .frame(width: 5, height: 5)
            Text(status)
                .font(.caption2.weight(.medium))
                .foregroundStyle(isHealthy ? Theme.positive : Theme.notice)
                .lineLimit(1)
        }
    }
}

struct AccountProfileCreationDesignSheet: View {
    let profileHomesByProvider: [String: [String]]
    let onCreate: (String, String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var providerID: String
    @State private var profileLabel: String
    @State private var profileHome: String
    @State private var commandCopied = false
    @State private var signInConfirmed = false

    init(
        initialProviderID: String,
        profileHomesByProvider: [String: [String]],
        onCreate: @escaping (String, String, String) -> Void
    ) {
        self.profileHomesByProvider = profileHomesByProvider
        self.onCreate = onCreate
        _providerID = State(initialValue: initialProviderID)
        let initialHome = AccountSwitcherDesignData.nextProfileHome(
            providerID: initialProviderID,
            reservedHomes: profileHomesByProvider[initialProviderID, default: []]
        )
        _profileHome = State(initialValue: initialHome ?? "")
        _profileLabel = State(initialValue: AccountSwitcherDesignData.defaultProfileLabel(for: initialHome))
    }

    private var providerTitle: String {
        providerID == "claude" ? "Claude" : "Codex"
    }

    private var signInCommand: String? {
        guard let profileHome = usableProfileHome else { return nil }
        return AccountSwitcherDesignData.signInCommand(
            providerID: providerID,
            displayPath: profileHome
        )
    }

    private var reservedHomes: [String] {
        profileHomesByProvider[providerID, default: []]
    }

    private var generatedHome: String? {
        AccountSwitcherDesignData.nextProfileHome(
            providerID: providerID,
            reservedHomes: reservedHomes
        )
    }

    private var usableProfileHome: String? {
        let trimmedHome = profileHome.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHome.isEmpty,
              AccountSwitcherDesignData.isAvailableProfileHome(
                  providerID: providerID,
                  displayPath: trimmedHome,
                  reservedHomes: reservedHomes
              ) else {
            return nil
        }
        return trimmedHome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add \(providerTitle) Account")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.borderless)
            }

            Picker("Provider", selection: $providerID) {
                Text("Claude").tag("claude")
                Text("Codex").tag("codex")
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 10) {
                Text("Sign In")
                    .font(.callout.weight(.semibold))
                Text("OpenUsage will guide you through sign-in without changing your current account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let signInCommand {
                    signInStep(number: 1, title: "Open Terminal and run this new-account command") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(signInCommand)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 8) {
                                Button(commandCopied ? "Copied" : "Copy Command") {
                                    copySignInCommand()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button("Open Terminal…") {
                                    copySignInCommand()
                                    openTerminal()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        .padding(10)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        Text("This uses the new profile folder, so your current login stays unchanged.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    signInStep(number: 2, title: "Sign in for the new account") {
                        EmptyView()
                    }

                    signInStep(number: 3, title: "Confirm when you're finished") {
                        Button {
                            signInConfirmed = true
                        } label: {
                            Label(
                                signInConfirmed ? "Sign-In Complete" : "I've Finished Signing In",
                                systemImage: signInConfirmed ? "checkmark.circle.fill" : "checkmark.circle"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Text(
                        generatedHome == nil
                            ? "All \(AccountSwitcherDesignData.maxAccountCount) \(providerTitle) account slots are in use. "
                                + "Remove an account before adding another."
                            : "Choose an unused config folder before signing in."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Account Name")
                    .font(.callout.weight(.semibold))
                TextField("Account Name", text: $profileLabel)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Config Folder")
                    .font(.callout.weight(.semibold))
                TextField("~/.\(providerID)-alpha", text: $profileHome)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                if generatedHome != nil, usableProfileHome == nil {
                    Text("This folder is already in use or invalid.")
                        .font(.caption2)
                        .foregroundStyle(Theme.notice)
                }
            }

            Text(
                generatedHome == nil
                    ? "Remove an existing account to make a profile slot available."
                    : "The command uses this folder. Alpha and beta are suggested defaults, and you can edit the path."
            )
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer(minLength: 0)
                Button("Add Account") {
                    guard let usableProfileHome else { return }
                    onCreate(providerID, profileLabel, usableProfileHome)
                    dismiss()
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.small)
                .disabled(!signInConfirmed || usableProfileHome == nil)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onChange(of: providerID) {
            commandCopied = false
            signInConfirmed = false
            let nextHome = AccountSwitcherDesignData.nextProfileHome(
                providerID: providerID,
                reservedHomes: reservedHomes
            )
            profileHome = nextHome ?? ""
            profileLabel = AccountSwitcherDesignData.defaultProfileLabel(for: nextHome)
        }
        .onChange(of: profileHome) {
            commandCopied = false
            signInConfirmed = false
        }
    }

    private func signInStep<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.accentColor, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.caption.weight(.semibold))
                content()
            }
        }
    }

    private func copySignInCommand() {
        guard let signInCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(signInCommand, forType: .string)
        commandCopied = true
    }

    private func openTerminal() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
    }
}

struct AccountProfileManagementDesignSheet: View {
    let providerTitle: String
    let profile: AccountSwitcherMockProfile
    let onSave: (String, String) -> Void
    let onSignIn: () -> Void
    let onRemove: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var profileLabel: String
    @State private var profileHome: String

    init(
        providerTitle: String,
        profile: AccountSwitcherMockProfile,
        onSave: @escaping (String, String) -> Void,
        onSignIn: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.providerTitle = providerTitle
        self.profile = profile
        self.onSave = onSave
        self.onSignIn = onSignIn
        self.onRemove = onRemove
        _profileLabel = State(initialValue: profile.label)
        _profileHome = State(initialValue: profile.detail)
    }

    private var usableProfileHome: String? {
        let trimmedHome = profileHome.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHome.isEmpty ? nil : trimmedHome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Manage \(providerTitle) Account")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button("Done") {
                    guard let usableProfileHome else { return }
                    onSave(profileLabel, usableProfileHome)
                    dismiss()
                }
                .buttonStyle(.borderless)
                .disabled(usableProfileHome == nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Account Name")
                    .font(.callout.weight(.semibold))
                TextField("Account Name", text: $profileLabel)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Config Folder")
                    .font(.callout.weight(.semibold))
                TextField("Config Folder", text: $profileHome)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            AccountStatusBadge(status: profile.status, isHealthy: profile.isHealthy)

            HStack {
                if !profile.isHealthy {
                    Button("Sign In…") {
                        guard let usableProfileHome else { return }
                        onSave(profileLabel, usableProfileHome)
                        onSignIn()
                        dismiss()
                    }
                    .glassButtonStyle(prominent: true)
                    .controlSize(.small)
                }
                Spacer(minLength: 8)
                Button("Remove Account", role: .destructive) {
                    onRemove()
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}
