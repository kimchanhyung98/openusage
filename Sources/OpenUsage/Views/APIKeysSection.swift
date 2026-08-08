import SwiftUI

/// 프로바이더 Customize 상세의 API-key 카드 — 상태 dot + Add/Edit 확장 에디터.
/// 저장 키는 auth store가 읽는 config 파일에 기록, config > env — 저장은 곧 env 키 override.
/// 저장/삭제 후 실패 backoff 해제 + 강제 refresh로 대시보드 즉시 갱신.
struct APIKeysSection: View {
    let provider: any APIKeyManaging
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    @State private var isOpen = false
    /// 표시용 상태 캐시 — appear 시 seed, save/clear 후 재조회 (렌더마다 파일 미접근).
    @State private var status: APIKeyStatus = .notSet

    // 일시적 에디터 상태 — 에디터 열림·save/clear 시 리셋
    @State private var revealDisplay = false
    @State private var revealInput = false
    @State private var overrideChecked = false
    @State private var input = ""
    @State private var revealedKey: String?
    @State private var actionError: String?

    private static let inputPlaceholder = "sk-or-v1-…"

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("API Key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                providerRow
                if isOpen {
                    Divider()
                    editorBlock
                }
            }
            .cardSurface()
            // recessed 에디터 배경이 카드 라운드 모서리를 벗어나지 않도록 클리핑
            .clipShape(Theme.cardShape)
        }
        .onAppear { status = provider.apiKeyStatus }
    }

    // MARK: - Rows

    private var providerRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.provider.icon)
                .frame(width: 18, height: 18)
            Text(provider.provider.displayName)
            Spacer(minLength: 8)
            statusDot
            Button(isOpen ? "Done" : (status == .notSet ? "Add" : "Edit")) {
                toggleExpand()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    /// 이진 상태 dot — 키 없음 red, 사용 가능 green.
    private var statusDot: some View {
        let color = status == .notSet ? Color(nsColor: .systemRed) : Color(nsColor: .systemGreen)
        return Circle().fill(color).frame(width: 6, height: 6)
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if status == .notSet {
                // 키 전무: 처음부터 편집 가능
                keyField(editable: true)
                primaryButton("Save", disabled: !hasInput) { save() }
            } else if status == .fromEnvironment {
                // env 키만 존재: "Override" 체크 후 편집 가능
                keyField(editable: overrideChecked)
                if overrideChecked {
                    HStack(spacing: 8) {
                        primaryButton("Save", disabled: !hasInput) { save() }
                        ghostButton("Cancel") { overrideChecked = false; input = "" }
                    }
                } else {
                    Toggle("Override With a Custom Key", isOn: $overrideChecked)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
            } else {
                // saved/overrideActive: 커스텀 키 존재 — clear 시 env 키 또는 미설정으로 폴백
                keyField(editable: false)
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(.fill.quinary))
        .onChange(of: overrideChecked) { _, isOn in
            // override 진입 시 새 입력 시작, 해제 시 draft 폐기
            if isOn { input = ""; revealInput = false }
        }
    }

    /// 단일 필드 — read-only(소스 힌트/공개 키 표시)와 editable(`input` 바인딩) 모드.
    @ViewBuilder
    private func keyField(editable: Bool) -> some View {
        if editable {
            APIKeyField(
                text: $input,
                placeholder: Self.inputPlaceholder,
                readOnly: false,
                displayText: "",
                reveal: revealInput,
                onReveal: { revealInput.toggle() },
                onClear: nil
            )
        } else {
            let hint = sourceHint
            let display = revealDisplay ? (revealedKey ?? hint) : hint
            // 저장(config) 키만 앱에서 삭제 가능 — env 전용 키는 삭제 불가, override 삭제는 env 폴백
            let onClear: (() -> Void)? = (status == .saved || status == .overrideActive)
                ? { remove() }
                : nil
            APIKeyField(
                text: .constant(""),
                placeholder: "",
                readOnly: true,
                displayText: display,
                reveal: revealDisplay,
                onReveal: { toggleRevealDisplay() },
                onClear: onClear
            )
        }
    }

    private var sourceHint: String {
        switch status {
        case .fromEnvironment: "From Your Environment"
        case .saved: "Saved in App"
        case .overrideActive: "Custom Key"
        case .notSet: ""
        }
    }

    private var hasInput: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func primaryButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(disabled)
    }

    private func ghostButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
    }

    // MARK: - Actions

    private func refreshStatus() {
        status = provider.apiKeyStatus
    }

    private func toggleExpand() {
        if isOpen {
            isOpen = false
        } else {
            isOpen = true
            resetEditor()
            refreshStatus()
        }
    }

    private func resetEditor() {
        revealDisplay = false
        revealInput = false
        overrideChecked = false
        input = ""
        revealedKey = nil
        actionError = nil
    }

    private func toggleRevealDisplay() {
        revealDisplay.toggle()
        if revealDisplay { revealedKey = provider.currentAPIKey() }
    }

    private func save() {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try provider.saveAPIKey(key)
            resetEditor()
            refreshStatus()
            triggerRefresh()
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "API key save failed for \(provider.provider.id): \(error.localizedDescription)")
        }
    }

    private func remove() {
        do {
            try provider.deleteAPIKey()
            resetEditor()
            refreshStatus()
            triggerRefresh()
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.auth, "API key delete failed for \(provider.provider.id): \(error.localizedDescription)")
        }
    }

    /// 실패 backoff 해제 + 강제 refresh로 새 키 데이터 즉시 반영. 비활성 프로바이더면 refresh만 no-op.
    private func triggerRefresh() {
        let id = provider.provider.id
        dataStore.clearFailureBackoff(for: id)
        Task { await dataStore.refresh(providerID: id, force: true) }
    }
}

/// API-key 입력 필드 — 네이티브 bordered 필드 + 선행 clear(선택) + 후행 eye 토글.
/// read-only는 비활성 네이티브 필드 — eye·clear는 필드 밖 sibling이라 클릭 가능 유지.
private struct APIKeyField: View {
    @Binding var text: String
    var placeholder: String
    var readOnly: Bool
    var displayText: String
    var reveal: Bool
    var onReveal: () -> Void
    var onClear: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if let onClear {
                fieldIcon("xmark.circle.fill", action: onClear, label: "Clear")
            }
            Group {
                if readOnly {
                    TextField(placeholder, text: .constant(displayText))
                        .disabled(true)
                } else if reveal {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            fieldIcon(reveal ? "eye.slash" : "eye", action: onReveal, label: reveal ? "Hide" : "Show")
        }
    }

    private func fieldIcon(_ symbol: String, action: @escaping () -> Void, label: String) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}
