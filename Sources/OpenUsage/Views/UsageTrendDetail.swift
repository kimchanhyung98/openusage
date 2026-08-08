import SwiftUI

/// Usage Trend 행의 상세 팝오버 — 확대 바 차트, peak/호버 일자 readout, 소스 노트.
struct UsageTrendDetail: View {
    let title: String
    let points: [MetricChartPoint]
    let note: String?
    /// 커서의 팝오버 내부 여부 보고 — 행에서 차트로 이동하는 동안 열림 유지용.
    var onHoverChange: (Bool) -> Void

    @State private var activeIndex: Int?

    private static let chartHeight: CGFloat = 76
    private static let width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            axis
            if let note, !note.isEmpty {
                PopoverSourceNote(text: note)
            }
        }
        .padding(12)
        .frame(width: Self.width)
        // 팝오버가 열린 채 refresh로 `points` 교체 가능 — 선택 해제로 stale 하이라이트 방지
        .onChange(of: points) { activeIndex = nil }
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false); activeIndex = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(readout)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        let maxValue = max(1, points.map(\.value).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(points.indices, id: \.self) { index in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.chartHeight)
                    // 짧은 바도 쉽게 hit되도록 전체 컬럼을 hover 대상화
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Theme.meterFill(.normal))
                            .frame(height: barHeight(points[index].value, max: maxValue))
                            .opacity(activeIndex == nil || activeIndex == index ? 1 : 0.35)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { activeIndex = index }
                    }
            }
        }
        .frame(height: Self.chartHeight)
        // 바 영역 이탈 시(팝오버 내부라도) 선택 해제 — readout이 마지막 바에 고정되지 않고 peak로 복귀
        .onContinuousHover { phase in if case .ended = phase { activeIndex = nil } }
        .animation(.easeOut(duration: 0.12), value: activeIndex)
    }

    private var axis: some View {
        HStack {
            Text(points.first?.label ?? "")
            Spacer()
            Text(points.last?.label ?? "")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var peakIndex: Int? { points.indices.max { points[$0].value < points[$1].value } }

    /// 호버 중인 일자 수치, 미호버 시 peak 수치.
    private var readout: String {
        if let activeIndex, points.indices.contains(activeIndex) {
            return "\(points[activeIndex].label) · \(points[activeIndex].readout)"
        }
        if let peakIndex { return "peak \(points[peakIndex].readout)" }
        return ""
    }

    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        guard value > 0 else { return 2 }
        return max(Self.chartHeight * 0.06, Self.chartHeight * min(1, value / maxValue))
    }
}

// 호버 개폐 코디네이터는 `HoverPopoverState` 소유 (모델 분해 팝오버와 공유)
