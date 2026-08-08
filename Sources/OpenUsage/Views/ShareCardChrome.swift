import SwiftUI

/// 공유 카드 PNG 공용 chrome (`ShareCardView`, `TotalSpendShareCardView`).
/// `ImageRenderer`에 window 배경이 없어 불투명 배경 필수, tooltip은 AppKit 앵커가 노란 박스로 래스터화되어 차단.
struct ShareCardChrome<Content: View>: View {
    let appearance: ColorScheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
            watermarkFooter
        }
        .padding(16)
        .frame(width: ShareCardView.width, alignment: .topLeading)
        .background(Theme.traySurface)
        .environment(\.colorScheme, appearance)
        .environment(\.hoverTooltipsDisabled, true)
    }

    private var watermarkFooter: some View {
        HStack(spacing: 6) {
            ProviderIcon(source: .providerMark("openusage"), inset: 0)
                .frame(width: 14, height: 14)
            Text("Monitor Your AI Subscriptions with OpenUsage")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
