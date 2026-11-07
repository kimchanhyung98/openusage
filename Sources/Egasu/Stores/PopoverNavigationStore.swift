import Observation

/// 메뉴바 popover 내 표시 화면 — Customize·Settings는 dashboard를 제자리 교체, Esc는 dashboard로 복귀
enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case customize
    case settings

    /// 화면 전환 slide의 좌→우 순서 rank — 높은 rank로 가면 trailing, 낮은 rank로 가면 leading에서 진입
    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .customize: 1
        case .settings: 2
        }
    }
}

/// popover 내 navigation — 표시 화면, Customize master/detail route, 화면 전환 slide bookkeeping
/// `LayoutStore`에서 분리된 화면 routing 전담 — 기존 `screen`/`isEditing` 등 표면은 `LayoutStore`가 전달
@MainActor
@Observable
final class PopoverNavigationStore {
    /// 현재 표시 중인 in-popover 화면 — footer 버튼·Esc handler·popover 닫힘 reset 공용
    var screen = PopoverScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // SwiftUI `onChange`는 한 frame 늦어 목적지가 먼저 그려짐 — 변경과 동기로 기록해
            // DashboardView가 다음 render에서 떠나는 화면 기준 slide 수행
            screenSlideFrom = oldValue
            screenSlideID += 1
            // Customize 이탈 시 L2 detail 선택 해제 — 재진입 시 항상 리스트 표시, 닫힘 reset(`screen = .dashboard`)도 동일 경로
            if screen != .customize { customizeProviderID = nil }
        }
    }
    /// 화면 전환 slide 지원 상태 — 떠난 화면과 전환마다 증가하는 counter, UI 전용 (미persist)
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    /// Customize 표시 여부 — edit mode 관점 호출자를 위한 `screen` bridge
    var isEditing: Bool {
        get { screen == .customize }
        set { screen = newValue ? .customize : .dashboard }
    }
    /// Customize detail(L2) 표시 중인 provider — `nil`이면 L1 리스트, UI 전용으로 Customize 이탈·popover 닫힘 시 해제
    var customizeProviderID: String?
}
