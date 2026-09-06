import SwiftUI

/// Provider 카드 안의 metric 한 줄: bounded(`limit != nil`)는 label+meter+텍스트 행, unbounded는 bar 없는 text-only 행.
/// 메뉴 바와 동일한 `WidgetData` 사용 — layout만 다름.
struct WidgetRowView: View {
    let data: WidgetData
    /// 전역 relative/absolute reset 표시 토글 — 정적 컨텍스트(drag-reorder preview 등)에서는 `nil`이라
    /// reset label이 plain text로 렌더링.
    var onToggleResetDisplay: (() -> Void)?
    /// 전역 Used/Left meter 스타일 토글 — `onToggleResetDisplay`와 동일한 공급 규칙.
    var onToggleMeterStyle: (() -> Void)?
    /// 이 text-only 행이 다른 text-only 행 바로 아래에 있는지 여부 — 행은 이웃을 모르므로 리스트가 공급.
    var condensedTop: Bool = false

    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue
    @State private var modelHover = HoverPopoverState()
    /// resets popover의 claim 흐름을 이 행의 카드로 라우팅 — live dashboard 밖(preview, share render)에서는
    /// `nil`이라 timeline이 read-only.
    @Environment(\.codexResetClaim) private var codexResetClaim
    /// Party easter egg — meter bar를 severity 색 대신 party gradient로 채움.
    @Environment(\.popoverPartyMode) private var partyMode

    /// 행 폰트는 density 설정에서 결정 — padding이 아닌 point size 차이가 Compact를 실제 밀도 높은 모드로 만듦.
    private var labelFont: Font {
        .system(size: density.labelPointSize, weight: .semibold)
    }

    private var supportingFont: Font {
        .system(size: density.supportingPointSize, weight: .regular)
    }

    var body: some View {
        // reset 날짜가 있는 행은 시계 기반 상태를 위해 30초 tick으로 re-render — TimelineView는 popover 표시 중에만
        // tick 스케줄, 날짜 없는 행은 static.
        Group {
            if data.resetsAt != nil || !data.expiriesAt.isEmpty {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    rowContent
                }
            } else {
                rowContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        // bar 행은 넓게, 한 줄 text 행은 좁게 — 연속 한 줄 행이 cluster로 읽히게 하는 rhythm.
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
    }

    private var topPadding: CGFloat {
        if data.isBounded { return density.barRowPadding }
        return condensedTop ? density.condensedTextRowTopPadding : density.textRowPadding
    }

    private var bottomPadding: CGFloat {
        data.isBounded ? density.barRowPadding : density.textRowPadding
    }

    @ViewBuilder
    private var rowContent: some View {
        if data.isChart, data.hasData {
            // 실데이터 없는 chart는 unbounded "No data" 행으로 fall through — descriptor template 데이터 누출 방지.
            UsageSparkline(data: data)
        } else if data.isBounded {
            boundedRow
        } else {
            unboundedRow
        }
    }

    private var boundedRow: some View {
        let state = data.meterState()
        return VStack(alignment: .leading, spacing: density.rowInnerSpacing) {
            boundedLabelRow(state)
            meter(state)
            primaryTextRow
        }
    }

    /// Label과 같은 줄 오른쪽의 단일 pace 경고 slot — `MeterState`에 따라 escalate. flame만 severity 색을 갖고
    /// copy는 secondary. 경고가 공간을 우선하고 제목이 truncate.
    private func boundedLabelRow(_ state: WidgetData.MeterState) -> some View {
        HStack(spacing: 6) {
            Text(data.title)
                .font(labelFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .accessibilityHint(data.softLimitStatusText ?? "")
            warning(state)
        }
    }

    /// 상태별 경고 표시 — state를 exhaustive하게 switch해 copy가 bar와 모순되지 않게 보장.
    @ViewBuilder
    private func warning(_ state: WidgetData.MeterState) -> some View {
        switch state {
        case .spent:
            flameWarning(text: "Limit reached", state: state, accessibility: "Limit reached")
        case .runningOut(let eta, _):
            // `eta == nil`(float-edge)이면 flame 단독 표시 — projection은 tooltip에. 시간이 보이면
            // reset label처럼 클릭으로 전역 countdown/exact 모드 토글.
            flameWarning(text: eta, state: state,
                         accessibility: eta ?? "Will reach limit",
                         action: eta == nil ? nil : onToggleResetDisplay)
        case .closeToLimit(let spare, _):
            Spacer(minLength: 8)
            Text(spare)
                .font(supportingFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .hoverTooltip(state.tooltip)
        case .healthy where data.alwaysShowPacing:
            // "always show pacing": on-track 행에도 projection 표시 — copy 자체가 projection이므로 flame/tooltip 없음.
            if let projection = state.tooltip {
                Spacer(minLength: 8)
                Text(projection)
                    .font(supportingFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        case .noData, .healthy, .level:
            EmptyView()
        }
    }

    /// Flame 아이콘 + 선택적 경고 텍스트 — spent/running-out 공용. `action`이 있으면 plain button으로 wrap.
    @ViewBuilder
    private func flameWarning(text: String?, state: WidgetData.MeterState,
                              accessibility: String, action: (() -> Void)? = nil) -> some View {
        Spacer(minLength: 8)
        let label = HStack(spacing: 3) {
            Image(systemName: "flame.fill")
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(severityColor(state.severity))
                .accessibilityHidden(true) // 옆의 경고 텍스트가 메시지를 전달
            if let text {
                Text(text)
                    .font(supportingFont)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .foregroundStyle(.secondary)
        .hoverTooltip(state.tooltip)
        .accessibilityLabel(accessibility)

        if let action {
            Button(action: action) { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    private func severityColor(_ severity: WidgetData.MeterSeverity?) -> AnyShapeStyle {
        severity.map(Theme.meterFill) ?? AnyShapeStyle(Color.secondary)
    }

    private var primaryTextRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            headlineText
            Spacer(minLength: 8)
            trailingContext
        }
        .font(supportingFont)
        .lineLimit(1)
    }

    // headline 값은 행의 payload — `.primary`, 주변 컨텍스트는 `.secondary`.
    @ViewBuilder
    private var headlineText: some View {
        if data.hasMeterStyleToggle, let onToggleMeterStyle {
            Button(action: onToggleMeterStyle) {
                Text(data.headline)
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
            .hoverTooltip(data.meterStyleTooltip)
        } else {
            Text(data.headline)
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var trailingContext: some View {
        if let text = data.boundedTrailingText() {
            if data.hasResetLabel(), let onToggleResetDisplay {
                Button(action: onToggleResetDisplay) {
                    Text(text).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .hoverTooltip(data.resetTooltip())
            } else {
                Text(text).foregroundStyle(.secondary)
                    .hoverTooltip(data.resetTooltip())
            }
        }
    }

    private var unboundedRow: some View {
        unboundedRowContent
            .onChange(of: data.modelBreakdown) { _, _ in modelHover.dismiss() }
            // refresh가 credits를 교체하면 stale timeline 위의 popover를 dismiss — 단 claim이 pin 중이면 유지:
            // claim의 강제 refresh가 원인이므로 닫으면 결과 banner가 렌더링되지 못함.
            .onChange(of: data.expiriesAt) { _, _ in
                if !modelHover.isPinned { modelHover.dismiss() }
            }
            .onDisappear { modelHover.dismiss() }
    }

    /// 값 column의 hover highlight 여부 — pointer 진입 즉시 점등, popover가 열려 있는 동안 유지.
    /// 두 flag 모두 `modelHover` 소유라 panel close 경로(`dismissAll`)가 highlight까지 정리.
    private var showValueHighlight: Bool {
        hasHoverPopover && (modelHover.overInline || modelHover.isPresented)
    }

    /// 값 column이 hover popover를 여는지 — spend 행의 model breakdown 또는 Codex resets 행의 timeline.
    /// resets 행은 "0 available"(빈 `expiriesAt`)에도 열리되 실데이터 필수 — "No data" tile이
    /// "zero credits"로 읽히는 popover를 열면 안 됨.
    private var hasHoverPopover: Bool {
        data.hasModelBreakdown || (data.showsResetExpiries && data.hasData)
    }

    private var unboundedRowContent: some View {
        HStack(alignment: .center, spacing: 10) {
            labelColumn
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    expiryStatusDot
                    Text(data.unboundedDetail)
                        .font(supportingFont)
                        .foregroundStyle(.primary) // 값은 행의 payload — bounded headline과 동일
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        // hover 대상은 행 전체가 아닌 값 텍스트. popover가 wire된 행은 tooltip 억제 —
                        // 같은 hover를 두 surface가 다투지 않게 처리.
                        .hoverTooltip(hasHoverPopover ? nil : data.unboundedValueTooltip)
                }
                if let subtitle = data.unboundedSubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .multilineTextAlignment(.trailing)
            // hover 시 값 뒤의 quaternary chip — negative inset이라 행 높이 불변.
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -7)
                    .padding(.vertical, -4)
                    .opacity(showValueHighlight ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.12), value: showValueHighlight)
            // hover trigger와 popover anchor 모두 값 column에 부착 — label hover로는 breakdown이 열리지 않고
            // 화살표가 값에 center.
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard hasHoverPopover else {
                    modelHover.dismiss()
                    return
                }
                if case .active = phase {
                    modelHover.inlineHover(true)
                } else {
                    modelHover.inlineHover(false)
                }
            }
            .popover(
                isPresented: Binding(
                    get: { hasHoverPopover && modelHover.isPresented },
                    // click-outside dismiss는 `.ended` hover 없이 detail을 제거하므로 dismiss()로 상태 정리.
                    set: { if !$0 { modelHover.dismiss() } }
                ),
                arrowEdge: .top
            ) {
                if let breakdown = data.modelBreakdown {
                    ModelUsageDetail(title: data.title, breakdown: breakdown) { inside in
                        modelHover.detailHover(inside)
                    }
                } else if data.showsResetExpiries {
                    RateLimitResetsDetail(
                        count: data.resetCreditCount, expiries: data.expiriesAt,
                        onHoverChange: { inside in modelHover.detailHover(inside) },
                        onPinChange: { pinned in modelHover.setPinned(pinned) },
                        // claim은 이 행의 card service로 실행 — 비가역 claim이 카드가 보여주는 계정의 credential을 소비.
                        // environment 부재(preview, share render)나 provider id 미지정이면 timeline은 read-only.
                        claim: codexResetClaim
                            .flatMap { router in data.providerID.flatMap { router.service(for: $0) } }
                            .map { service in
                                { expiry, redeemRequestID in
                                    await service.claim(creditExpiringAt: expiry, redeemRequestID: redeemRequestID)
                                }
                            }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var expiryStatusDot: some View {
        if let severity = data.expirySeverity() {
            Circle()
                .fill(severityColor(severity))
                .frame(width: 6, height: 6)
                .accessibilityLabel(expiryStatusAccessibilityLabel(severity))
        }
    }

    private func expiryStatusAccessibilityLabel(_ severity: WidgetData.MeterSeverity) -> String {
        switch severity {
        case .normal: return "Reset credits expire in more than 7 days"
        case .warning: return "A reset credit expires within 7 days"
        case .critical: return "A reset credit expires within 48 hours"
        }
    }

    private var labelColumn: some View {
        HStack(spacing: 4) {
            Text(data.title)
                .font(.system(size: density.supportingPointSize, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            unknownModelWarningIcon
        }
    }

    @ViewBuilder
    private var unknownModelWarningIcon: some View {
        if data.hasUnknownModels {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: density.supportingPointSize - 1))
                .foregroundStyle(severityColor(.warning))
                .hoverTooltip(data.unknownModelTooltip)
                .accessibilityLabel("This period used a model with unknown pricing")
        }
    }

    /// Full-width capsule meter — fill 색이 pace verdict를 표현(의도적으로 native Gauge/ProgressView가 아님),
    /// 데이터 없으면 비어 있고 무색. pace tick은 overlay로 얹혀 bar 높이를 바꾸지 않음.
    private func meter(_ state: WidgetData.MeterState) -> some View {
        let tick = data.paceTick(for: state)
        let softLimitMarker = data.softLimitMarkerFraction
        return GeometryReader { proxy in
            // tick은 `.overlay`로 상하 돌출 — ZStack sibling이면 stack이 자라 bar가 두꺼워짐.
            ZStack(alignment: .leading) {
                // semantic quaternary fill — glass 위에서 vibrant 유지, 접근성 설정에 적응.
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(partyMode ? PartyMode.meterFill : severityColor(state.severity))
                    .frame(width: fillWidth(track: proxy.size.width))
            }
            .overlay(alignment: .leading) {
                if let tick {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.55))
                        .frame(width: Self.paceTickWidth, height: density.meterHeight + Self.paceTickOverhang)
                        .offset(
                            x: MeterMarkerGeometry.offset(
                                track: proxy.size.width,
                                fraction: tick,
                                markerWidth: Self.paceTickWidth
                            )
                        )
                }
            }
            .overlay(alignment: .leading) {
                if let softLimitMarker {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: Self.softLimitMarkerWidth, height: density.meterHeight)
                        .offset(
                            x: MeterMarkerGeometry.offset(
                                track: proxy.size.width,
                                fraction: softLimitMarker,
                                markerWidth: Self.softLimitMarkerWidth
                            )
                        )
                }
            }
        }
        .frame(height: density.meterHeight)
        .animation(Motion.spring, value: data.fraction)
        .animation(Motion.spring, value: data.softLimitMarkerFraction)
        .accessibilityHidden(true)
        .hoverTooltip(data.meterTooltip(for: state))
    }

    private static let paceTickWidth: CGFloat = 2
    private static let paceTickOverhang: CGFloat = 4
    private static let softLimitMarkerWidth: CGFloat = 1

    /// 최소 가시 규칙이 적용된 fill 폭 — 0이 아닌 fraction은 최소 원 하나(bar 높이) 폭으로 렌더링해
    /// 1–2%가 보이지 않는 sliver가 되지 않게 보장.
    private func fillWidth(track: CGFloat) -> CGFloat {
        guard data.hasData, data.fraction > 0 else { return 0 }
        return max(density.meterHeight, track * data.fraction)
    }
}

/// meter marker를 fraction 중심에 배치하되 track 양 끝을 넘지 않게 clamp.
enum MeterMarkerGeometry {
    static func offset(track: CGFloat, fraction: Double, markerWidth: CGFloat) -> CGFloat {
        let centered = track * fraction - markerWidth / 2
        return min(max(centered, 0), max(track - markerWidth, 0))
    }
}
