import SwiftUI

/// Customize 프로바이더 목록 (L1). 비활성 프로바이더도 회색으로 포함.
/// 행 탭은 L2 진입, 활성 프로바이더만 grip 드래그로 재정렬 가능.
struct CustomizeProviderListView: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(AppContainer.self) private var container
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeProviderID: String?
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    private var orderedRows: [ProviderRow] { layout.customizeProviderRows }

    var body: some View {
        VStack(alignment: .leading, spacing: density.sectionSpacing) {
            VStack(spacing: 0) {
                ForEach(orderedRows) { row in
                    providerRow(row)
                }
            }
            .cardSurface()
            ScreenCrossLinkRow(
                systemImage: "gearshape",
                title: "Settings",
                subtitle: "Notifications, appearance and more",
                destination: .settings
            )
        }
        .animation(Motion.spring, value: orderedRows.map(\.id))
    }

    private func providerRow(_ row: ProviderRow) -> some View {
        ProviderListRow(
            provider: row.provider,
            isEnabled: row.isEnabled,
            metricCount: row.metricCount,
            // 드래그 재정렬은 활성 프로바이더만 — 비활성 행의 grip은 무반응 (탭·토글은 동작)
            handle: { grip in
                if row.isEnabled {
                    AnyView(grip.highPriorityGesture(providerDragGesture(for: row)))
                } else {
                    grip
                }
            },
            onToggle: { container.setProviderEnabled($0, for: row.id) },
            onOpen: { withAnimation(Motion.spring) { layout.customizeProviderID = row.id } }
        )
        .opacity(activeProviderID == row.id ? 0 : 1)
        .reorderFrame(id: row.id, in: .named(reorderSpaceName))
    }

    private func providerDragGesture(for row: ProviderRow) -> some Gesture {
        reorderDragGesture(
            id: row.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeProviderID,
            lift: $reorderLift,
            makeLift: { makeProviderLift(for: row, value: $0) },
            // 재정렬 hit-test 대상은 활성 프로바이더만 — 비활성 행은 대상 제외
            orderedIDs: { layout.customizeGroups.map(\.provider.id) },
            reorder: { layout.reorderProvider(dragged: row.id, target: $0) }
        )
    }

    private func makeProviderLift(for row: ProviderRow, value: DragGesture.Value) -> ReorderLift? {
        ReorderLift.make(
            id: row.id,
            payload: .customizeProviderRow(provider: row.provider, isEnabled: row.isEnabled, metricCount: row.metricCount),
            value: value,
            frames: rowFrames
        )
    }
}
