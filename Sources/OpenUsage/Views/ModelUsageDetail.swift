import SwiftUI

/// spend 기간 호버 상세 — 모델별 순위 목록 (이름/비용, 점유율/토큰, 비례 share 바).
struct ModelUsageDetail: View {
    let title: String
    let breakdown: ModelUsageBreakdown
    var onHoverChange: (Bool) -> Void

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    private static let width: CGFloat = 280

    var body: some View {
        let shares = Self.shares(for: breakdown.models)
        let percents = Self.wholePercents(shares)
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(alignment: .leading, spacing: 0) {
                ForEach(breakdown.models.indices, id: \.self) { index in
                    modelRow(breakdown.models[index], share: shares[index], percent: percents[index])
                }
            }
            PopoverSourceNote(text: breakdown.sourceNote)
        }
        .padding(14)
        .frame(width: Self.width)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                onHoverChange(true)
            case .ended:
                onHoverChange(false)
            }
        }
    }

    private var header: some View {
        Text(title)
            .font(.system(size: density.headerPointSize, weight: .semibold))
            .foregroundStyle(.primary)
    }

    private func modelRow(_ model: ModelUsageEntry, share: Double, percent: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.model)
                    .font(.system(size: density.supportingPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let cost = model.costUSD {
                    Text(MetricFormatter.number(cost, kind: .dollars, style: .row))
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                } else {
                    Text("\u{2014}")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: density.supportingPointSize))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(percent)%")
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(MetricFormatter.string(
                    for: MetricValue(number: Double(model.totalTokens), kind: .count, label: "tokens"),
                    style: .row
                ))
                .monospacedDigit()
            }
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)

            GeometryReader { proxy in
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Theme.meterFill(.normal))
                            .frame(width: proxy.size.width * share)
                    }
            }
            .frame(height: density.meterHeight)
            .padding(.top, 2)
        }
        .padding(.vertical, density.textRowPadding)
    }

    /// 목록 모델 자체 수치 합 기준 share 산출 — 별도 경로에서 반올림되는 `totalCostUSD` 사용 시 표기 수치와 괴리 발생.
    /// 단일 기준 원칙: 전 모델이 priced일 때만 cost share, 미가격 모델이 하나라도 있으면 전 행 token share 폴백.
    static func shares(for models: [ModelUsageEntry]) -> [Double] {
        let allPriced = models.allSatisfy { $0.costUSD != nil }
        if allPriced {
            let costTotal = models.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
            if costTotal > 0 {
                return models.map { model in
                    min(max((model.costUSD ?? 0) / costTotal, 0), 1)
                }
            }
        }
        let tokenTotal = models.reduce(0) { $0 + $1.totalTokens }
        guard tokenTotal > 0 else { return models.map { _ in 0 } }
        return models.map { model in
            min(max(Double(model.totalTokens) / Double(tokenTotal), 0), 1)
        }
    }

    /// 합계가 정확히 100이 되는 정수 백분율 (largest-remainder rounding). 전부 0인 share는 0 유지.
    static func wholePercents(_ shares: [Double]) -> [Int] {
        guard shares.contains(where: { $0 > 0 }) else { return shares.map { _ in 0 } }
        let raw = shares.map { $0 * 100 }
        var percents = raw.map { Int($0.rounded(.down)) }
        var leftover = 100 - percents.reduce(0, +)
        guard leftover > 0 else { return percents }
        let byRemainder = raw.indices.sorted {
            let lhs = raw[$0] - raw[$0].rounded(.down)
            let rhs = raw[$1] - raw[$1].rounded(.down)
            if lhs != rhs { return lhs > rhs }
            return $0 < $1
        }
        for index in byRemainder where leftover > 0 {
            percents[index] += 1
            leftover -= 1
        }
        return percents
    }
}
