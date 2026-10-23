import SwiftUI

struct LanguageSettingsRow: View {
    @Binding var selection: LanguageSetting
    var activeLanguage: LanguageSetting = .active
    @State private var relauncher = AppRelauncher()
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(L10n.settings("Language"))
                Spacer(minLength: 8)
                Picker("", selection: $selection) {
                    ForEach(LanguageSetting.allCases, id: \.self) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(relauncher.isRestarting)
                .onChange(of: selection) { _, selected in
                    LanguageSetting.update(to: selected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)

            if selection != activeLanguage {
                Text(L10n.settings("Restart OpenUsage to apply the language change."))
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: relauncher.restart) {
                    Text(L10n.settings("Restart Now"))
                        .frame(maxWidth: .infinity)
                }
                .glassButtonStyle()
                .controlSize(.regular)
                .disabled(relauncher.isRestarting)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                if let errorMessage = relauncher.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.notice)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
