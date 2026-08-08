import SwiftUI

/// Customize(L1)·Settings 마지막 카드 아래에 고정되는 상호 교차 링크 행.
/// 두 화면을 혼동해 잘못 들어온 사용자를 목적지로 안내하는 용도.
struct ScreenCrossLinkRow: View {
    @Environment(LayoutStore.self) private var layout

    let systemImage: String
    let title: String
    let subtitle: String
    let destination: PopoverScreen

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        Button {
            withAnimation(Motion.modeSwitch) {
                layout.screen = destination
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: density.headerPointSize, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: density.planBadgePointSize))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, density.controlRowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardSurface()
    }
}
