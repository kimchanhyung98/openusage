import SwiftUI

/// 라이브 대시보드 리스트와 드래그 프리뷰가 공유하는 그룹 메트릭 카드 본체.
/// 두 표면이 같은 구조를 거치게 해 프리뷰와 라이브 카드의 드리프트 방지.
struct DashboardMetricCard<Rows: View>: View {
    @ViewBuilder var rows: Rows

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        VStack(spacing: 0) {
            rows
        }
        .padding(.vertical, density.cardGutter)
        .cardSurface()
    }
}
