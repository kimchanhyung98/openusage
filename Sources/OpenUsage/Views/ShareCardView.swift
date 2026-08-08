import SwiftUI

/// 우클릭 "Share Screenshot" 액션용 프로바이더 사용량 오프스크린 PNG.
/// 팝오버의 현재 카드 상태(caret 확장 포함)를 정적 스냅샷으로 미러링, ×4 래스터화.
/// 환경 의존 없는 `[WidgetData]` 입력 — 앱·테스트에서 동일 렌더 보장.
struct ShareCardView: View {
    let provider: Provider
    var plan: String?
    let rows: [WidgetData]
    let appearance: ColorScheme
    /// On Demand 행 시작 인덱스 (Always Visible 수) — 이웃 condensing이 expand caret을 하드 경계로 취급.
    /// 축소 상태(확장 섹션 없음)면 `nil`.
    var expandBoundaryIndex: Int? = nil
    /// 세션 중 rename된 라이브 카드 제목. `ImageRenderer`는 앱 environment 밖이라 명시 전달 필수.
    var displayNameOverride: String? = nil

    /// 저작 카드 폭 (pt). 렌더러가 `ShareCardRenderer.scale` 배율 적용, 높이는 행 합산으로 가변.
    static let width: CGFloat = 360

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            metricsCard
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: 22, height: 22)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayNameOverride ?? provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Body

    /// `WidgetRowView` 재사용으로 라이브 대시보드와 일치하는 정적 렌더. 빈 프로바이더는 플레이스홀더 표시.
    @ViewBuilder
    private var metricsCard: some View {
        if rows.isEmpty {
            DashboardMetricCard {
                Text("No metrics to show")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        } else {
            DashboardMetricCard {
                let condensed = Self.condensedTextRowIndices(rows, boundary: expandBoundaryIndex)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, data in
                    WidgetRowView(data: data, condensedTop: condensed.contains(index))
                }
            }
        }
    }

    /// 다른 텍스트 행 아래에서 condense되는 텍스트 행의 flat 인덱스 (라이브 대시보드와 동일 규칙 공유).
    /// expand caret은 하드 경계 — 세그먼트별 개별 스캔 후 로컬 오프셋을 flat 인덱스로 매핑.
    static func condensedTextRowIndices(_ rows: [WidgetData], boundary: Int? = nil) -> Set<Int> {
        let edges = boundary.map { [0, $0, rows.count] } ?? [0, rows.count]
        var indices = Set<Int>()
        for (lower, upper) in zip(edges, edges.dropFirst()) {
            let offsets = WidgetData.condensedTextRowOffsets(in: Array(rows[lower..<upper]))
            indices.formUnion(offsets.map { lower + $0 })
        }
        return indices
    }

}
