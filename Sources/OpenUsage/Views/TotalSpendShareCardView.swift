import SwiftUI

/// Total Spend 카드 공유 액션용 오프스크린 PNG — `ShareCardView`의 집계판.
/// 본문은 `TotalSpendRingContent` 재사용으로 팝오버 표시와 동일한 링·범례 보장.
struct TotalSpendShareCardView: View {
    let total: TotalSpend
    let metric: TotalSpendMetric
    let appearance: ColorScheme

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            DashboardMetricCard {
                TotalSpendRingContent(projection: projection)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metric.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Text(total.period.rawValue)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
