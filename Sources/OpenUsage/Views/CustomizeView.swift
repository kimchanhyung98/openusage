import SwiftUI

/// Customize 화면 — 프로바이더 목록(L1)과 상세(L2)의 2단 master/detail.
/// 재정렬은 pasteboard 드래그 대신 `DragGesture` + 로컬 row geometry 사용.
/// 라우트 `customizeProviderID`는 `LayoutStore` 소유 — 팝오버 닫힘 리셋·Esc 핸들러와 동일 상태 공유.
struct CustomizeView: View {
    @Environment(LayoutStore.self) private var layout
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]

    var body: some View {
        PopoverScrollView {
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        // star/거부 알림 필 — 성공은 green, 프로바이더별 상한 거부는 orange
        .overlay(alignment: .bottom) {
            if layout.customizationNotice != nil {
                customizationNoticePill
                    .padding(.bottom, 12)
            }
        }
        .animation(Motion.spring, value: layout.customizationNotice)
        .animation(Motion.spring, value: layout.customizationNoticeTrigger)
    }

    private var customizationNoticePill: some View {
        let isNotice = layout.customizationNoticeTone == .notice
        return TransientPill(
            systemImage: isNotice ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
            text: layout.customizationNotice ?? "",
            tint: isNotice ? Theme.notice : Theme.positive,
            trigger: layout.customizationNoticeTrigger,
            showsShadow: false
        )
    }

    @ViewBuilder
    private var content: some View {
        if let id = layout.customizeProviderID {
            CustomizeProviderDetailView(
                providerID: id,
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                rowFrames: rowFrames
            )
            .transition(.move(edge: .trailing))
        } else {
            CustomizeProviderListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                rowFrames: rowFrames
            )
            .transition(.move(edge: .leading))
        }
    }
}
