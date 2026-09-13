import SwiftUI

struct SoftLimitThresholdField: View {
    let settings: SoftLimitSettingsStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @State private var text: String
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(settings: SoftLimitSettingsStore) {
        self.settings = settings
        _text = State(initialValue: String(settings.thresholdPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Threshold")
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    TextField("90", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 60)
                        .accessibilityLabel("Soft Limit Threshold Percent")
                        .focused($isFocused)
                        .onSubmit { save() }
                    Text("%")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
        .onChange(of: text) { errorMessage = nil }
        .onChange(of: settings.thresholdPercent) { _, percent in
            if !isFocused { text = String(percent) }
        }
        .onDisappear { save() }
    }

    private func save() {
        guard settings.setThreshold(from: text) else {
            errorMessage = "Enter a whole number from 1 to 100. \(settings.thresholdPercent)% is still applied."
            return
        }
        text = String(settings.thresholdPercent)
        errorMessage = nil
    }
}
