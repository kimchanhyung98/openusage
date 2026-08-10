import SwiftUI

/// 프로바이더 단일 Customize 상세 (L2) — Always Visible·On Demand 두 카드, grip 드래그로 카드 간 이동.
/// 드래그 제스처는 행이 아닌 컨테이너 소유 — per-row 제스처는 행이 두 카드의 `ForEach` 사이를 건널 때
/// SwiftUI가 행과 제스처를 함께 해제해 드래그 중단.
struct CustomizeProviderDetailView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let providerID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeMetricID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        if let group = layout.customizeDetail(for: providerID) {
            VStack(alignment: .leading, spacing: density.sectionSpacing) {
                metricSections(group)
                    .simultaneousGesture(metricDragGesture())
                if let keyProvider = container.apiKeyProviders.first(where: { $0.provider.id == providerID }) {
                    APIKeysSection(provider: keyProvider)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.spring, value: layout.expandedMetricIDs)
        } else {
            // 미지의 프로바이더 — L1이 알려진 프로바이더만 노출하므로 실질적 도달 불가
            EmptyView()
        }
    }

    private func metricSections(_ group: ProviderMetrics) -> some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            metricSection("Always Visible", metrics: group.alwaysShownMetrics, providerID: group.provider.id)
            metricSection("On Demand", metrics: group.expandedMetrics, providerID: group.provider.id)
        }
    }

    // MARK: - Metric sections

    private func metricSection(_ title: String, metrics: [WidgetDescriptor], providerID: String) -> some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                if metrics.isEmpty {
                    emptyDropZone(providerID: providerID)
                } else {
                    ForEach(metrics, id: \.id) { metric in
                        metricRow(metric, in: providerID)
                    }
                }
            }
            .cardSurface()
        }
    }

    /// 빈 섹션의 대시 드롭 타깃. divider의 reorder frame 보유 — 드롭 시 `applyMetricDividerOrder`로 섹션 이동.
    private func emptyDropZone(providerID: String) -> some View {
        let yOutset = max(0, (density.estimatedMetricRowHeight - 30) / 2)
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .foregroundStyle(.tertiary)
            .frame(height: 30)
            .padding(8)
            .overlay(
                Text("Drag metrics here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            )
            .reorderFrame(id: expandedDividerID(for: providerID), in: .named(reorderSpaceName), yOutset: yOutset)
            .accessibilityLabel("Drag metrics here")
    }

    private func metricRow(_ metric: WidgetDescriptor, in providerID: String) -> some View {
        let isActive = activeMetricID == metric.id
        return CustomizeMetricRow(
            title: metric.title,
            // grip은 시각 전용 + frame 발행 ("grip:<metric>") — 드래그 제스처는 섹션 스택 소유 (`metricDragGesture`)
            handle: { grip in
                AnyView(grip.reorderFrame(id: "grip:\(metric.id)", in: .named(reorderSpaceName)))
            },
            trailing: {
                StarButton(metric: metric)
                Toggle("", isOn: Binding(
                    get: { layout.isMetricEnabled(metric.id) },
                    set: { layout.setMetricEnabled(metric.id, $0) }
                ))
                .settingsSwitchStyle()
            }
        )
        .contentShape(Rectangle())
        .opacity(isActive ? 0 : 1)
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    // MARK: - Container drag-reorder

    /// 섹션 스택 단일 드래그 제스처 — 메트릭이 두 카드 사이를 건너도 드래그 유지.
    /// 시작 시 포인터 아래 grip으로 대상 식별, 이후 행·divider frame hit-test로 재정렬.
    private func metricDragGesture() -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(reorderSpaceName))
            .onChanged { value in
                if activeMetricID == nil {
                    if let id = metricID(at: value.startLocation) {
                        activeMetricID = id
                        if let lift = makeLift(metricID: id, value: value) {
                            reorderLift = lift
                        }
                    }
                }
                guard let id = activeMetricID else { return }
                reorderLift?.location = value.location
                let divider = expandedDividerID(for: providerID)
                let ordered = reorderTargetIDs(for: providerID)
                guard let target = reorderTarget(at: value.location, in: rowFrames, excluding: id, orderedIDs: ordered),
                      let next = LayoutStore.reordered(ordered, dragged: id, target: target) else { return }
                withAnimation(Motion.spring) {
                    _ = layout.applyMetricDividerOrder(next, dragged: id, dividerID: divider, in: providerID)
                }
            }
            .onEnded { _ in
                activeMetricID = nil
                reorderLift = nil
            }
    }

    /// 드래그 시작점의 grip frame hit-test로 대상 메트릭 식별. grip 밖 시작이면 `nil`.
    private func metricID(at point: CGPoint) -> String? {
        for (key, frame) in rowFrames {
            guard key.hasPrefix("grip:"), frame.insetBy(dx: 0, dy: -2).contains(point) else { continue }
            return String(key.dropFirst("grip:".count))
        }
        return nil
    }

    private func reorderTargetIDs(for providerID: String) -> [String] {
        layout.metricOrderWithDivider(for: providerID, dividerID: expandedDividerID(for: providerID))
    }

    private func expandedDividerID(for providerID: String) -> String {
        "\(providerID)::expanded-divider"
    }

    private func makeLift(metricID: String, value: DragGesture.Value) -> ReorderLift? {
        let title = layout.customizeDetail(for: providerID)?.metrics.first { $0.id == metricID }?.title ?? ""
        return ReorderLift.make(id: metricID, payload: .customizeMetric(title: title), value: value, frames: rowFrames)
    }
}

/// 메트릭 행의 star(메뉴바 pin) 컨트롤. 탭 시 확인 필, 프로바이더별 상한 초과 시 shake + 거부 필.
private struct StarButton: View {
    let metric: WidgetDescriptor
    @Environment(LayoutStore.self) private var layout
    @State private var shakeTrigger = 0

    var body: some View {
        if metric.pinnable {
            let pinned = layout.isPinned(metric.id)
            Button {
                if layout.canPin(metric.id) {
                    layout.togglePin(metric.id)
                    layout.presentCustomizationNotice(pinned ? "Removed from menu bar" : "Starred for menu bar")
                } else {
                    shakeTrigger += 1
                    layout.presentCustomizationNotice(layout.pinDenialReason(metric.id) ?? "Up to 2 stars per provider", tone: .notice)
                }
            } label: {
                Image(systemName: pinned ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            .denyShake(trigger: shakeTrigger)
            .animation(Motion.spring, value: pinned)
        }
    }
}
