import SwiftUI

/// 라이브 행과 드래그 프리뷰가 공유하는 Customize 메트릭 행 레이아웃 (grip · label · star · toggle).
/// grip 슬롯을 한 곳에 정의해 프리뷰와 라이브 행의 픽셀 일치 보장.
struct CustomizeMetricRow<Handle: View, Trailing: View>: View {
    let title: String
    /// 선행 drag grip 래핑. 라이브 행은 재정렬 제스처 주입, 프리뷰는 그대로 통과.
    let handle: (AnyView) -> Handle
    @ViewBuilder var trailing: Trailing

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        HStack(spacing: 10) {
            handle(AnyView(ReorderGrip()))
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }
}

extension CustomizeMetricRow where Handle == AnyView {
    /// 드래그 프리뷰용 정적 변형 — grip 제스처 없음.
    init(title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(title: title, handle: { $0 }, trailing: trailing)
    }
}

/// 드래그 프리뷰가 라이브 `Toggle` 자리에 그리는 정적 스위치 플레이스홀더.
struct CustomizeSwitchPlaceholder: View {
    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: 28, height: 16)
    }
}

/// 드래그 프리뷰가 star 버튼 자리에 그리는 정적 플레이스홀더.
struct CustomizeStarPlaceholder: View {
    var body: some View {
        Image(systemName: "star")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.quaternary)
            .frame(width: 18, height: 18)
    }
}
