import AppKit
import SwiftUI

/// 프로바이더 카드 확장 영역의 퀵링크 버튼 행. 최대 3열, 초과분은 다음 행으로 래핑.
struct ProviderLinksView: View {
    let links: [ProviderLink]
    /// 메트릭 행 inset과 일치 필수 — 위아래 행과의 정렬 유지.
    private static let horizontalInset: CGFloat = 14

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    /// 열 상한 — 링크 수와 무관하게 3열 초과 금지.
    private static let maxColumns = 3

    private var columns: [GridItem] {
        let count = min(Self.maxColumns, max(1, links.count))
        return Array(repeating: GridItem(.flexible(), spacing: density.expandedGridSpacing, alignment: .top),
                     count: count)
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: density.expandedGridSpacing) {
            ForEach(links, id: \.self) { link in
                linkButton(link)
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.top, density.textRowPadding)
        .padding(.bottom, density.textRowPadding)
    }

    private func linkButton(_ link: ProviderLink) -> some View {
        Button {
            if let url = URL(string: link.url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 4) {
                Text(link.label)
                    .font(.system(size: density.supportingPointSize, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: density.supportingPointSize - 2))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("\(link.label), opens in browser")
    }
}
