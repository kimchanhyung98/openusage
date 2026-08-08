import SwiftUI

struct ReorderLift {
    enum Payload {
        case dashboardProvider(provider: Provider, plan: String?, rows: [WidgetData])
        case dashboardMetric(data: WidgetData)
        case customizeProviderRow(provider: Provider, isEnabled: Bool, metricCount: Int)
        case customizeMetric(title: String)
    }

    let id: String
    let payload: Payload
    let sourceFrame: CGRect
    let touchOffset: CGPoint
    var location: CGPoint

    /// drag value로부터 lift를 생성하는 단일 지점 — 재정렬 사이트별 차이는 `payload`뿐.
    /// 드래그된 행의 frame 미기록 시 `nil` 반환.
    static func make(
        id: String,
        payload: Payload,
        value: DragGesture.Value,
        frames: [String: CGRect]
    ) -> ReorderLift? {
        guard let sourceFrame = frames[id] else { return nil }
        return ReorderLift(
            id: id,
            payload: payload,
            sourceFrame: sourceFrame,
            touchOffset: CGPoint(
                x: value.startLocation.x - sourceFrame.minX,
                y: value.startLocation.y - sourceFrame.minY
            ),
            location: value.location
        )
    }
}

struct ReorderLiftPreview: View {
    let lift: ReorderLift

    // 프리뷰는 라이브 화면과 동일 뷰 재사용 — density도 함께 읽어 모든 density에서 원본 블록과 일치
    @AppStorage(DensitySetting.key) private var density = DensitySetting.defaultValue

    var body: some View {
        preview
            .frame(width: lift.sourceFrame.width)
            .scaleEffect(1.025)
            .shadow(color: .black.opacity(0.18), radius: 14, x: 0, y: 8)
            .position(
                x: lift.location.x - lift.touchOffset.x + lift.sourceFrame.width / 2,
                y: lift.location.y - lift.touchOffset.y + lift.sourceFrame.height / 2
            )
            .animation(.none, value: lift.location)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var preview: some View {
        switch lift.payload {
        case .dashboardProvider(let provider, let plan, let rows):
            dashboardProviderPreview(provider: provider, plan: plan, rows: rows)
        case .dashboardMetric(let data):
            dashboardMetricPreview(data)
        case .customizeProviderRow(let provider, let isEnabled, let metricCount):
            customizeProviderRowPreview(provider: provider, isEnabled: isEnabled, metricCount: metricCount)
        case .customizeMetric(let title):
            customizeMetricPreview(title)
        }
    }

    private func dashboardProviderPreview(provider: Provider, plan: String?, rows: [WidgetData]) -> some View {
        // 라이브 대시보드 섹션과 동일 구성 (헤더 + 공유 메트릭 카드)
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            ProviderSectionHeader(provider: provider, plan: plan)
                .padding(.horizontal, 8)

            DashboardMetricCard {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    WidgetRowView(data: row)
                }
            }
        }
    }

    private func dashboardMetricPreview(_ data: WidgetData) -> some View {
        WidgetRowView(data: data)
            .liftedRowSurface()
    }

    private func customizeProviderRowPreview(provider: Provider, isEnabled: Bool, metricCount: Int) -> some View {
        // 라이브 L1 행과 동일 구성의 비활성 렌더 — 프리뷰 전체가 non-interactive
        ProviderListRow(
            provider: provider,
            isEnabled: isEnabled,
            metricCount: metricCount,
            handle: { $0 }
        )
        .liftedRowSurface()
    }

    private func customizeMetricPreview(_ title: String) -> some View {
        CustomizeMetricRow(title: title,
            trailing: {
                CustomizeStarPlaceholder()
                CustomizeSwitchPlaceholder()
            }
        )
        .liftedRowSurface()
    }

}

/// 팝오버 내부 재정렬용 경량 in-view geometry.
/// 이 팝오버에서 신뢰 불가한 pasteboard 기반 `.draggable`/`.dropDestination` 대신 `DragGesture` + row frame 비교 사용.
struct ReorderFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func reorderFrame(id: String, in coordinateSpace: CoordinateSpace, yOutset: CGFloat = 0) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ReorderFramePreferenceKey.self,
                    value: [id: proxy.frame(in: coordinateSpace).insetBy(dx: 0, dy: -yOutset)]
                )
            }
        )
    }
}

/// 대시보드·Customize의 프로바이더/메트릭 공용 drag-to-reorder 제스처.
/// lift 추적·타깃 hit-test·spring·haptic은 공통, 호출자는 차이점만 주입.
@MainActor
func reorderDragGesture(
    id: String,
    coordinateSpaceName: String,
    rowFrames: [String: CGRect],
    active: Binding<String?>,
    lift: Binding<ReorderLift?>,
    makeLift: @escaping (DragGesture.Value) -> ReorderLift?,
    orderedIDs: @escaping () -> [String],
    reorder: @escaping (_ target: String) -> Bool
) -> some Gesture {
    DragGesture(minimumDistance: 4, coordinateSpace: .named(coordinateSpaceName))
        .onChanged { value in
            active.wrappedValue = id
            if lift.wrappedValue?.id != id, let newLift = makeLift(value) {
                lift.wrappedValue = newLift
            }
            lift.wrappedValue?.location = value.location
            guard let target = reorderTarget(
                at: value.location,
                in: rowFrames,
                excluding: id,
                orderedIDs: orderedIDs()
            ) else { return }
            var moved = false
            withAnimation(Motion.spring) {
                moved = reorder(target)
            }
            if moved { Haptics.snap() }
        }
        .onEnded { _ in
            active.wrappedValue = nil
            lift.wrappedValue = nil
        }
}

func reorderTarget(
    at location: CGPoint,
    in frames: [String: CGRect],
    excluding draggedID: String,
    orderedIDs: [String]
) -> String? {
    guard let from = orderedIDs.firstIndex(of: draggedID) else { return nil }
    let crossingThreshold = 0.20

    for id in orderedIDs where id != draggedID {
        guard let to = orderedIDs.firstIndex(of: id),
              let frame = frames[id]
        else { continue }

        guard frame.insetBy(dx: 0, dy: -2).contains(location) else { continue }

        // 타깃 행에 일정 비율 진입한 후에만 재정렬 — 경계 진입 즉시 이동하는 튐 방지
        if to > from {
            return location.y >= frame.minY + frame.height * crossingThreshold ? id : nil
        } else {
            return location.y <= frame.maxY - frame.height * crossingThreshold ? id : nil
        }
    }

    return nil
}
