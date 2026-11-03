import CoreGraphics
import Observation

/// 팝오버 auto-fit 높이 계산부 — 화면별 측정값을 이상 높이(morph 목표)로 합산·클램프.
/// 애니메이션은 `DashboardView` 소유, 여기는 결정적 측정·목표 계산만 담당.
/// 뷰가 `@State`로 보유, `measuredIdeal` 변경이 morph `onChange` 트리거.
@MainActor
@Observable
final class PanelHeightCoordinator {
    /// 화면별 이상 window 높이 (top bar + footer + scroll content) — morph 목표값.
    private(set) var measuredIdeal: [PopoverScreen: CGFloat] = [:]

    @ObservationIgnored private var measuredScrollContent: [PopoverScreen: CGFloat] = [:]
    @ObservationIgnored private var measuredFooter: [PopoverScreen: CGFloat] = [:]
    @ObservationIgnored private let topBarHeight: CGFloat

    init(topBarHeight: CGFloat) {
        self.topBarHeight = topBarHeight
    }

    /// 화면의 scroll-content 측정 높이 기록 및 ideal 재구성.
    func setScrollContent(_ height: CGFloat, for screen: PopoverScreen) {
        measuredScrollContent[screen] = height
        recomposeIdeal(for: screen)
    }

    /// 화면의 footer 측정 높이 기록 및 ideal 재구성.
    func setFooter(_ height: CGFloat, for screen: PopoverScreen) {
        measuredFooter[screen] = height
        recomposeIdeal(for: screen)
    }

    /// 측정값 합산으로 화면 ideal 재구성. 대시보드는 top bar 제외.
    /// scroll content 미측정(0) 시 ideal 미설정 유지 — 실측 전까지 기존 크기 보존.
    private func recomposeIdeal(for screen: PopoverScreen) {
        guard let content = measuredScrollContent[screen], content > 0 else { return }
        let topBar: CGFloat = screen == .dashboard ? 0 : topBarHeight
        let footer = measuredFooter[screen] ?? 0
        measuredIdeal[screen] = topBar + footer + content
    }

    /// 화면의 클램프된 목표 높이. 미측정 시 `nil`.
    func target(for screen: PopoverScreen) -> CGFloat? {
        measuredIdeal[screen].map(clamped)
    }

    /// 패널 허용 범위 [min, screen-max]로 클램프 — 훅 미설정 시 identity.
    private func clamped(_ ideal: CGFloat) -> CGFloat {
        MenuBarPopover.clampHeight?(ideal) ?? ideal
    }
}
