import AppKit
import SwiftUI

/// 교차 프로바이더 Total Spend 카드 — 데이터 없는 조합은 empty state로 유지.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(AppContainer.self) private var container
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pickerNamespace

    /// 선택 기간 — 팝오버 닫힘·재실행에도 유지.
    @AppStorage("openusage.totalSpend.period") private var periodRawValue = TotalSpendPeriod.today.rawValue
    /// 선택 메트릭 — 동일하게 유지.
    @AppStorage("openusage.totalSpend.metric") private var metricRawValue = TotalSpendMetric.cost.rawValue
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    private var metric: TotalSpendMetric {
        TotalSpendMetric(rawValue: metricRawValue) ?? .cost
    }

    /// 집계 대상 — capability 기반 (`LayoutStore.spendCapableProviders`).
    /// Customize에서 행을 숨겨도 포함 유지, 유사 달러 행만 있는 프로바이더는 제외.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        // 다른 Mac에만 있는 동기화 계정도 합계·legend에 포함 — 이 기기 로그인 여부와 무관하게 전체 합 유지
        var aggregatedProviders = providers
        var aggregatedSnapshots = dataStore.snapshots
        for entry in dataStore.remoteOnlySpend {
            aggregatedProviders.append(entry.provider)
            aggregatedSnapshots[entry.provider.id] = entry.snapshot
        }
        // 제목은 registry 접근 가능한 이곳에서 해석 — legend와 share export 모두 라이브 rename 반영
        return TotalSpendAggregator.total(
            for: period,
            providers: aggregatedProviders,
            snapshots: aggregatedSnapshots,
            title: { container.displayName(for: $0) }
        )
    }

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            header
            card
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 5) {
            metricMenu
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .hoverTooltip(infoTooltip)
            Spacer(minLength: 8)
            shareButton
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
    }

    private var metricMenu: some View {
        Menu {
            ForEach(TotalSpendMetric.allCases) { option in
                Button {
                    metricRawValue = option.rawValue
                } label: {
                    if option == metric {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(metric.title)
                    .font(.system(size: density.headerPointSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Total Spend Metric")
        .accessibilityValue(metric.title)
    }

    /// 링에 실제 반영되는 프로바이더 목록 표기 — 하드코딩 목록 금지, tooltip의 거짓 방지.
    private var infoTooltip: String {
        let names = providers.map { container.displayName(for: $0) }
        return "Only includes \(names.formatted(.list(type: .and)))."
    }

    private var shareButton: some View {
        CopyFeedbackButton(accessibilityLabel: "Copy \(metric.title) Screenshot") {
            ShareCardRenderer.shareTotalSpend(
                total: total,
                metric: metric,
                appearance: colorScheme,
                layout: layout
            )
        }
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 12) {
            periodPicker
            if projection.isEmpty {
                emptyState
            } else {
                TotalSpendRingContent(projection: projection)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .animation(Motion.spring, value: periodRawValue)
        .animation(Motion.spring, value: metricRawValue)
        .contextMenu {
            Button("Share Screenshot") {
                ShareCardRenderer.shareTotalSpend(
                    total: total,
                    metric: metric,
                    appearance: colorScheme,
                    layout: layout
                )
            }
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TotalSpendPeriod.allCases) { candidate in
                periodSegment(candidate)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func periodSegment(_ candidate: TotalSpendPeriod) -> some View {
        let isSelected = candidate == period
        return Button {
            periodRawValue = candidate.rawValue
        } label: {
            Text(candidate.shortLabel)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .matchedGeometryEffect(id: "totalSpendPeriod", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: periodRawValue)
    }

    /// 표시할 데이터 없는 조합은 spend 타일의 "No data" 규칙 준수 — 0 링 조작 금지.
    private var emptyState: some View {
        Text(metric.emptyMessage)
            .font(.system(size: density.supportingPointSize))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// 라이브 카드와 share export가 공유하는 링 본체.
/// 프로바이더 ID로 섹터 identity를 고정해 기간 전환 때 각도만 애니메이션.
struct TotalSpendRingContent: View {
    let projection: TotalSpendProjection

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    private static let ringDiameter: CGFloat = 104

    var body: some View {
        HStack(spacing: 18) {
            ring
            legend
        }
    }

    // MARK: - Ring

    /// 슬라이스 최소 점유율 — 극소 프로바이더도 sliver 유지. 표시 전용, legend·중앙 값은 실제 금액.
    private static let minimumSliceShare = 0.025

    private var ring: some View {
        ZStack {
            // identity는 프로바이더 ID — 양쪽 상태에 존재하면 arc 각도만 애니메이션, 입·퇴장은 fade
            ForEach(arcs) { arc in
                RingSectorShape(startFraction: arc.start, endFraction: arc.end)
                    .fill(TotalSpendPalette.color(for: arc.providerID))
            }
            centerLabel
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let center = formatValue(projection.centerValue, style: .full)
        switch projection.metric {
        case .cost:
            return "Total cost \(center) across \(projection.slices.count) providers"
        case .tokens:
            return "Total tokens \(center) across \(projection.slices.count) providers"
        case .costPerMtok:
            return "Blended cost per megatoken \(center) across \(projection.slices.count) providers"
        }
    }

    private struct RingArc: Identifiable, Equatable {
        let providerID: String
        var start: Double
        var end: Double

        var id: String { providerID }
    }

    /// 누적 링 fraction으로 변환한 순위 슬라이스 — 최소 점유율 적용 후 재정규화로 링 폐합 보장.
    private var arcs: [RingArc] {
        let totalDisplay = projection.slices.reduce(0) { $0 + $1.displayAmount }
        guard totalDisplay > 0 else { return [] }
        let floored = projection.slices.map { max($0.displayAmount / totalDisplay, Self.minimumSliceShare) }
        let sum = floored.reduce(0, +)
        guard sum > 0 else { return [] }

        var cursor = 0.0
        return zip(projection.slices, floored).map { slice, share in
            let width = share / sum
            defer { cursor += width }
            return RingArc(providerID: slice.provider.id, start: cursor, end: cursor + width)
        }
    }

    private var centerLabel: some View {
        let center = MetricFormatter.totalSpendRingCenter(projection.centerValue, metric: projection.metric)
        return VStack(spacing: 1) {
            Text(center.primary)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(center.unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .hoverTooltip(centerTooltip)
    }

    private var centerTooltip: String {
        let exact = formatValue(projection.centerValue, style: .full)
        if projection.isEstimated, projection.metric.usesDollarEstimateNote {
            return "\(exact) · \(WidgetData.localEstimateNote)"
        }
        return exact
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(projection.slices) { slice in
                legendRow(slice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendRow(_ slice: TotalSpendProjectedSlice) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TotalSpendPalette.color(for: slice.provider.id))
                .frame(width: 8, height: 8)
            Text(slice.title)
                .font(.system(size: density.supportingPointSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // 토큰은 legend에서 항상 축약 (`.full`은 자릿수 넘침), cost 모드는 센트 유지
            Text(formatValue(slice.displayAmount, style: legendValueStyle))
                .font(.system(size: density.supportingPointSize, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private var legendValueStyle: MetricFormatter.Style {
        switch projection.metric {
        case .tokens: .row
        case .cost, .costPerMtok: .full
        }
    }

    private func formatValue(_ value: Double, style: MetricFormatter.Style) -> String {
        switch projection.metric {
        case .cost:
            return MetricFormatter.number(value, kind: .dollars, style: style)
        case .tokens:
            return MetricFormatter.number(value, kind: .count, style: style)
        case .costPerMtok:
            return MetricFormatter.costPerMtok(value, style: style)
        }
    }
}

/// 프로바이더 ID에 고정된 브랜드 색상 — 기간·순위 변화에도 색 유지.
/// 검정 브랜드는 양 appearance에서 읽히도록 동적 색상 사용.
enum TotalSpendPalette {
    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),
        "codex": hex(0x10A37F),
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),  // 브랜드 블랙 (#13120A), 다크 모드에서 near-white 반전
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),    // 브랜드 블랙, Cursor와 구분 위해 gray 오프셋
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),  // OpenCode — grayscale 브랜드, medium gray
        "openrouter": hex(0x6467F2),
        "antigravity": hex(0x4285F4),
        "copilot": hex(0xA855F7),
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6)
    ]

    /// 팔레트 미등록 프로바이더용 결정적 backstop 색 — ID 키잉으로 기간·재실행 간 색 고정.
    private static let fallback: [Color] = [
        hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)
    ]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 순수 검정 브랜드용 light/dark adaptive 색 — 다크 카드에서의 비가시성 방지.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
