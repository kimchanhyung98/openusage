import SwiftUI

struct TokscaleSettingsSection: View {
    @Bindable var store: TokscaleSyncStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    @State private var isNameSheetPresented = false
    @State private var isLoginSheetPresented = false

    private static let privacyURL = URL(string: "https://tokscale.ai/privacy")!
    fileprivate static let bunInstallationURL = URL(string: "https://bun.com/docs/installation")!

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header

            VStack(alignment: .leading, spacing: 0) {
                actionRow
                disclosure

                if store.phase != .idle {
                    Divider()
                    status
                }

                if !store.output.isEmpty {
                    Divider()
                    commandOutput
                }
            }
            .cardSurface()
        }
        .sheet(isPresented: $isNameSheetPresented) {
            TokscaleDeviceNameSheet(store: store)
        }
        .sheet(isPresented: $isLoginSheetPresented) {
            TokscaleLoginSheet(store: store)
        }
        .onAppear {
            store.refreshCooldown()
        }
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Tokscale")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                isNameSheetPresented = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.settings("Manage Tokscale Device Name"))
            .disabled(store.isRunning)
        }
        .padding(.horizontal, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text(L10n.settings("Usage Sync"))
                Link(destination: Self.privacyURL) {
                    Image(systemName: "info.circle")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.settings("Tokscale Privacy Policy"))
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    @ViewBuilder
    private var action: some View {
        switch store.phase {
        case .installingBun:
            Button(L10n.settings("Installing…")) {}
                .disabled(true)
        case .submitting:
            Button(L10n.settings("Syncing…")) {}
                .disabled(true)
        case .loginRequired:
            Button(store.isRunning ? L10n.settings("Cancelling…") : L10n.settings("Log In…")) {
                isLoginSheetPresented = true
            }
            .disabled(store.isRunning)
        case .loggingIn:
            Button(L10n.settings("View Login…")) {
                isLoginSheetPresented = true
            }
        case .failed where store.failure == .login:
            Button(L10n.settings("Log In…")) {
                isLoginSheetPresented = true
            }
        case .idle, .submitFinished, .loginFinished, .failed:
            Button(L10n.settings("Sync")) {
                store.startSubmit()
            }
            .disabled(store.phase == .submitFinished || store.isSyncCoolingDown)
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.settings("Sync local usage to your public Tokscale profile."))
            if let nextSyncAllowedAt = store.nextSyncAllowedAt {
                Text(L10n.settings("Sync Available at %@", TimeFormatSetting.current.shortTime(nextSyncAllowedAt, base: L10n.locale)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if store.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusStyle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if canDismissResult {
                    Button(L10n.settings("Done")) {
                        withAnimation(Motion.spring) {
                            store.dismissResult()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if store.failure?.offersBunInstallationGuide == true {
                Link(L10n.settings("Open Bun Installation Guide"), destination: Self.bunInstallationURL)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canDismissResult: Bool {
        !store.isRunning && store.phase != .idle
    }

    private var statusMessage: String {
        switch store.phase {
        case .idle:
            ""
        case .installingBun:
            L10n.settings("Installing Bun…")
        case .submitting:
            L10n.settings("Running Tokscale…")
        case .loginRequired:
            store.isRunning ? L10n.settings("Cancelling Tokscale Login…") : L10n.settings("Login Required")
        case .submitFinished:
            L10n.settings("Tokscale Command Finished")
        case .loggingIn:
            L10n.settings("Waiting for Tokscale Login…")
        case .loginFinished:
            L10n.settings("Tokscale Login Finished. Sync Has Not Started.")
        case .failed:
            store.errorMessage ?? L10n.settings("Tokscale couldn't finish the command.")
        }
    }

    private var statusStyle: AnyShapeStyle {
        switch store.phase {
        case .loginRequired, .failed:
            Theme.notice
        default:
            AnyShapeStyle(.secondary)
        }
    }

    private var commandOutput: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.settings("Command Output"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TokscaleCommandOutput(output: store.output, height: 108)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct TokscaleDeviceNameSheet: View {
    @Bindable var store: TokscaleSyncStore

    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String
    @State private var errorMessage: String?

    init(store: TokscaleSyncStore) {
        self.store = store
        _draftName = State(initialValue: store.deviceName ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.settings("Tokscale Device Name"))
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button(L10n.settings("Cancel")) {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            Text(L10n.settings("This label appears publicly on your Tokscale profile. Saving it locally does not run Tokscale or make a network request."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.settings("Without an OpenUsage override, Tokscale can use TOKSCALE_DEVICE_NAME from your environment or the name stored for its stable device."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.settings("Device Name"))
                    .font(.callout.weight(.semibold))
                TextField(L10n.settings("Enter Device Name"), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack(alignment: .firstTextBaseline) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Theme.notice)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(L10n.settings("%d/%d bytes", trimmedByteCount, TokscaleDeviceName.maximumUTF8ByteCount))
                        .foregroundStyle(
                            trimmedByteCount > TokscaleDeviceName.maximumUTF8ByteCount
                                ? Theme.notice
                                : AnyShapeStyle(.secondary)
                        )
                }
                .font(.caption2)
            }

            HStack {
                if store.deviceName != nil {
                    Button(L10n.settings("Remove OpenUsage Override")) {
                        store.clearDeviceName()
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button(L10n.settings("Save")) {
                    save()
                }
                .glassButtonStyle(prominent: true)
                .controlSize(.small)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onChange(of: draftName) {
            errorMessage = nil
        }
    }

    private var trimmedByteCount: Int {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count
    }

    private func save() {
        do {
            try store.saveDeviceName(draftName)
            dismiss()
        } catch {
            errorMessage = UserFacingErrors.message(error)
        }
    }
}

private struct TokscaleLoginSheet: View {
    @Bindable var store: TokscaleSyncStore

    @Environment(\.dismiss) private var dismiss

    @State private var didStartLogin = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.settings("Log In to Tokscale"))
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button(closeButtonTitle) {
                    if store.phase == .loggingIn {
                        store.cancelLogin()
                    }
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            Text(L10n.settings("Tokscale uses GitHub for sign-in and may store your GitHub ID, username, display name, avatar, and email. A later sync can show your username, avatar, and display name on a public profile."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(L10n.settings("Login creates a personal token named CLI on <hostname>. It does not submit usage or change the public device name."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("bunx tokscale@latest login")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            loginState

            if showsLoginOutput, !store.output.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.settings("Login Output"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TokscaleCommandOutput(output: store.output, height: 150)
                }
            }

            if canStartLogin {
                HStack {
                    Spacer(minLength: 0)
                    Button(store.phase == .loginRequired ? L10n.settings("Log In") : L10n.settings("Try Again")) {
                        didStartLogin = true
                        store.startLogin()
                    }
                    .glassButtonStyle(prominent: true)
                    .controlSize(.small)
                }
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    @ViewBuilder
    private var loginState: some View {
        switch store.phase {
        case .loginRequired where !didStartLogin:
            Text(L10n.settings("Opening this sheet does not start login. Choose Log In to continue."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loggingIn:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(L10n.settings("Waiting for Tokscale Login…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loginFinished:
            Text(L10n.settings("Tokscale Login Finished. Sync Has Not Started."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            VStack(alignment: .leading, spacing: 7) {
                Text(store.errorMessage ?? L10n.settings("Tokscale couldn't finish login."))
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
                if store.failure?.offersBunInstallationGuide == true {
                    Link(L10n.settings("Open Bun Installation Guide"), destination: TokscaleSettingsSection.bunInstallationURL)
                        .font(.caption)
                }
            }
        default:
            EmptyView()
        }
    }

    private var closeButtonTitle: String {
        switch store.phase {
        case .loggingIn:
            L10n.settings("Cancel Login")
        case .loginFinished, .failed:
            L10n.settings("Done")
        default:
            L10n.settings("Cancel")
        }
    }

    private var showsLoginOutput: Bool {
        didStartLogin || store.phase == .loggingIn || store.phase == .loginFinished || store.failure == .login
    }

    private var canStartLogin: Bool {
        !store.isRunning && (store.phase == .loginRequired || (store.phase == .failed && store.failure == .login))
    }
}

private struct TokscaleCommandOutput: View {
    let output: String
    let height: CGFloat

    var body: some View {
        ScrollView(.vertical) {
            Text(verbatim: output)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .accessibilityLabel(L10n.settings("Tokscale Command Output"))
    }
}
