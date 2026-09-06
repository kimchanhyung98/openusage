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
                Divider()
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
    }

    private var header: some View {
        HStack(spacing: 5) {
            Text("Tokscale")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button("Name…") {
                isNameSheetPresented = true
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
            .disabled(store.isRunning)
        }
        .padding(.horizontal, 8)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Usage Sync")
                Text(store.deviceName.map { "Device: \($0)" } ?? "Uses Tokscale's Existing Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            Button("Installing…") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
        case .submitting:
            Button("Syncing…") {}
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(true)
        case .loginRequired:
            Button(store.isRunning ? "Cancelling…" : "Log In…") {
                isLoginSheetPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.isRunning)
        case .loggingIn:
            Button("View Login…") {
                isLoginSheetPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .failed where store.failure == .login:
            Button("Log In…") {
                isLoginSheetPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .idle, .submitFinished, .loginFinished, .failed:
            Button("Sync Now") {
                store.startSubmit()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Runs the Tokscale package resolved by bunx to update a public profile that may appear in search results. Tokscale decides which supported sources and fields to include.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The current CLI may publish usage, client, model, device, and discovered MCP-server information. Its current policy excludes prompts, responses, and source code.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("The package can access values exported by the app and your login shell, including credentials or other secrets. OpenUsage removes known runtime-injection settings and custom Tokscale API endpoints but cannot control code resolved by your Bun configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("bunx tokscale@latest submit")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("If Bun is unavailable, Sync Now installs it from bun.com, and the installer may update your login-shell profile. The installer and `tokscale@latest` can change without an OpenUsage update; bunx follows your Bun package configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Link("Privacy Policy", destination: Self.privacyURL)
                    .font(.caption)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var status: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if store.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusStyle)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.failure?.offersBunInstallationGuide == true {
                Link("Open Bun Installation Guide", destination: Self.bunInstallationURL)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusMessage: String {
        switch store.phase {
        case .idle:
            ""
        case .installingBun:
            "Installing Bun…"
        case .submitting:
            "Running Tokscale…"
        case .loginRequired:
            store.isRunning ? "Cancelling Tokscale Login…" : "Login Required"
        case .submitFinished:
            "Tokscale Command Finished"
        case .loggingIn:
            "Waiting for Tokscale Login…"
        case .loginFinished:
            "Tokscale Login Finished. Sync Has Not Started."
        case .failed:
            store.errorMessage ?? "Tokscale couldn't finish the command."
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
            Text("Command Output")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            TokscaleCommandOutput(output: store.output, height: 108)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TokscaleDeviceNameSheet: View {
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
                Text("Tokscale Device Name")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 12)
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            Text("This label appears publicly on your Tokscale profile. Saving it locally does not run Tokscale or make a network request.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Without an OpenUsage override, Tokscale can use `TOKSCALE_DEVICE_NAME` from your environment or the name stored for its stable device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Device Name")
                    .font(.callout.weight(.semibold))
                TextField("m1-max", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                HStack(alignment: .firstTextBaseline) {
                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(Theme.notice)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text("\(trimmedByteCount)/\(TokscaleDeviceName.maximumUTF8ByteCount) bytes")
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
                    Button("Remove OpenUsage Override") {
                        store.clearDeviceName()
                        dismiss()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                Spacer(minLength: 0)
                Button("Save") {
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
            errorMessage = error.localizedDescription
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
                Text("Log In to Tokscale")
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

            Text("Tokscale uses GitHub for sign-in and may store your GitHub ID, username, display name, avatar, and email. A later sync can show your username, avatar, and display name on a public profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Login creates a personal token named `CLI on <hostname>`. It does not submit usage or change the public device name.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("bunx tokscale@latest login")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

            loginState

            if showsLoginOutput, !store.output.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Login Output")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TokscaleCommandOutput(output: store.output, height: 150)
                }
            }

            if canStartLogin {
                HStack {
                    Spacer(minLength: 0)
                    Button(store.phase == .loginRequired ? "Log In" : "Try Again") {
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
            Text("Opening this sheet does not start login. Choose Log In to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .loggingIn:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for Tokscale Login…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .loginFinished:
            Text("Tokscale Login Finished. Sync Has Not Started.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failed:
            VStack(alignment: .leading, spacing: 7) {
                Text(store.errorMessage ?? "Tokscale couldn't finish login.")
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
                if store.failure?.offersBunInstallationGuide == true {
                    Link("Open Bun Installation Guide", destination: TokscaleSettingsSection.bunInstallationURL)
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
            "Cancel Login"
        case .loginFinished, .failed:
            "Done"
        default:
            "Cancel"
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
        .accessibilityLabel("Tokscale Command Output")
    }
}
