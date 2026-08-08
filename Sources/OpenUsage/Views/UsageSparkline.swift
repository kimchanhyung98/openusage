import SwiftUI

/// Usage Trend 행 — 우측 정렬 일별 토큰 sparkline. 호버 시 상세 차트(`UsageTrendDetail`) 노출.
/// 이미 산출된 `MetricChartPoint`만 그림 — 사용량 계산은 미수행.
struct UsageSparkline: View {
    let data: WidgetData
    /// 바·팝오버·접근성 라벨이 공유하는 단일 일별 포인트 목록.
    private let points: [MetricChartPoint]

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @State private var hover = HoverPopoverState()

    private static let maxChartWidth: CGFloat = 150
    private static let minChartWidth: CGFloat = 90
    private static let minBarWidth: CGFloat = 2

    init(data: WidgetData) {
        self.data = data
        self.points = data.chartPoints
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(data.title)
                .font(.system(size: density.supportingPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // 팝오버 앵커는 행 전체가 아닌 바 스트립 — 화살표가 차트를 직접 가리키도록
            bars
                // 포인터 진입 즉시 하이라이트, 팝오버 열림 동안 유지 — 패널 close 시 `hover.dismiss()`가 해제
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.quaternary)
                        .padding(.horizontal, -7)
                        .padding(.vertical, -4)
                        .opacity(showChartHighlight ? 1 : 0)
                }
                .animation(.easeOut(duration: 0.12), value: showChartHighlight)
                // 바 스트립만 hover 대상 — 제목 호버로는 상세 미노출
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
                }
                // click-away 해제는 `.ended` 호버 이벤트 없이 뷰 제거 — `overDetail` true 잔존 방지 위해 전체 상태 리셋 필수
                .popover(isPresented: Binding(get: { hover.isPresented }, set: { if !$0 { hover.dismiss() } }),
                         arrowEdge: .top) {
                    UsageTrendDetail(title: data.title, points: points, note: data.chartNote) { inside in
                        hover.detailHover(inside)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear { hover.dismiss() }
    }

    private var showChartHighlight: Bool {
        hover.overInline || hover.isPresented
    }

    private var bars: some View {
        let maxValue = max(1, points.map(\.value).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 1) {
            // day 라벨 키 (producer가 중복 일자 병합 보장) — refresh 시 위치 기반 바 재매핑 방지
            ForEach(points, id: \.label) { point in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.meterFill(.normal))
                    .frame(minWidth: Self.minBarWidth, maxWidth: .infinity)
                    .frame(height: barHeight(point.value, max: maxValue))
            }
        }
        .frame(minWidth: Self.minChartWidth, maxWidth: Self.maxChartWidth)
        .frame(height: density.trendChartHeight, alignment: .bottom)
    }

    /// 피크 대비 비례 높이. non-zero 일자는 최소 높이 보장, 0은 얇은 stub 유지.
    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        let height = density.trendChartHeight
        guard value > 0 else { return 2 }
        let ratio = min(1, value / maxValue)
        return max(height * 0.18, height * ratio)
    }

    private var accessibilityLabel: String {
        guard let peak = points.max(by: { $0.value < $1.value }),
              let first = points.first, let last = points.last else { return data.title }
        return "\(data.title): \(points.count) days, \(first.label) to \(last.label), peak \(peak.readout)."
    }
}
