import SwiftUI

/// Customize 프로바이더 목록(L1)의 단일 행.
/// grip·토글 제외 전 영역 탭 시 L2 진입, grip 드래그로 재정렬. 비활성 프로바이더도 열기 가능.
struct ProviderListRow<Handle: View>: View {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    let handle: (AnyView) -> Handle
    var onToggle: ((Bool) -> Void) = { _ in }
    var onOpen: () -> Void = {}

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    /// 카드 이름 변경 시 행 제목 동기화용.
    @Environment(AppContainer.self) private var container

    var body: some View {
        HStack(spacing: 10) {
            // grip은 open 대상 밖 — grip 탭으로는 L2 미진입
            handle(AnyView(ReorderGrip()))

            // Button 대신 contentShape + onTapGesture — 빈 공간 포함 전체 폭 hit-test 보장
            HStack(spacing: 10) {
                ProviderIcon(source: provider.icon)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(container.displayName(for: provider))
                        .font(.system(size: density.headerPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(metricCount) metrics")
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }

            Toggle("", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
                .settingsSwitchStyle()

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(container.displayName(for: provider))")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
        .opacity(isEnabled ? 1 : 0.55)
    }
}
