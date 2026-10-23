import SwiftUI

struct SoftLimitSettingsSection: View {
    let settings: SoftLimitSettingsStore
    let coordinator: SoftLimitCoordinator
    let providers: [Provider]
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @State private var confirmActivation = false

    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(L10n.settings("Soft Limit"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                HStack {
                    Text(L10n.settings("Enabled"))
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(
                        get: { settings.enabled },
                        set: { if $0 { confirmActivation = true } else { settings.enabled = false } }
                    ))
                    .settingsSwitchStyle()
                    .accessibilityLabel(L10n.settings("Enable Soft Limit"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, density.controlRowPadding)

                if settings.enabled {
                    HStack {
                        Text(L10n.settings("Window"))
                        Spacer(minLength: 8)
                        Picker(L10n.settings("Window"), selection: $settings.window) {
                            ForEach(SoftLimitWindow.allCases, id: \.self) { window in
                                Text(window.label).tag(window)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, density.controlRowPadding)
                    SoftLimitThresholdField(settings: settings)
                    notice(L10n.settings("Uses fresh quota data after the next successful refresh. Cancellation requires a verified client/account connection and must preserve apps, terminals, and conversations."))
                    ForEach(providers.filter { coordinator.status(for: $0.id).phase == .failed }) { provider in
                        notice(L10n.settings("%@: %@", provider.displayName, coordinator.status(for: provider.id).message))
                    }
                    DisclosureGroup(L10n.settings("Cancellation Status")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(providers) { provider in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName).font(.caption.weight(.semibold))
                                    Text(coordinator.status(for: provider.id).message)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                notice(L10n.settings("The Codex cancellation connection has been tested, but automatic cancellation is unavailable until account scope is verified. Other Codex sessions and other providers are not protected yet."))
                DisclosureGroup(L10n.settings("Connect Codex")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.settings("Start the local server, then open a Codex terminal connected to it:"))
                        Text("codex app-server daemon start\ncodex --remote unix://")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text(L10n.settings("Existing independent CLI, app, and IDE sessions are not connected automatically. OpenUsage does not restart them."))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .cardSurface()
        }
        .alert(L10n.settings("Enable Soft Limit?"), isPresented: $confirmActivation) {
            Button(L10n.settings("Enable"), role: .destructive) { settings.enabled = true }
            Button(L10n.settings("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.settings("Shows the limit guide and allows cancellation only for verified client/account connections. The current Codex connection is not account-verified and will not cancel tasks. Unconnected sessions and unsupported providers are not protected."))
        }
    }

    private func notice(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
