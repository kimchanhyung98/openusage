import SwiftUI

/// popover 콘텐츠 루트 — Dashboard·Customize·Settings 콘텐츠만 전환하고 chrome은 고정.
/// 화면별 auto-fit 높이와 수평 slide를 하나의 spring으로 구동.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverTransparencyStore.self) private var transparency
    @Environment(UpdaterController.self) private var updater
    @State private var reorderLift: ReorderLift?
    /// SwiftUI가 구동하는 panel 높이 — 단일 animation clock.
    /// 0은 미설정 sentinel: 첫 측정이 도착할 때까지 controller가 연 크기를 유지, 도착 시 애니메이션 없이 반영.
    @State private var animatedHeight: CGFloat = 0
    /// 이번 open에서 `animatedHeight`가 seed되었는지 여부 — seed 전 첫 establish는 un-animated, 이후 변경은 spring.
    @State private var didEstablishHeight = false
    /// 화면별 측정치를 clamp된 morph 목표로 합산하는 coordinator — 애니메이션은 이 view 소유, coordinator는 측정만 담당.
    @State private var heightCoordinator = PanelHeightCoordinator(topBarHeight: Self.topBarHeight)
    /// 화면 전환 slide 진행도 — 0은 outgoing, 1은 incoming 화면.
    @State private var slideProgress: CGFloat = 1
    /// slide 애니메이션이 시작된 `layout.screenSlideID` — store의 id를 따라잡기 전에는 outgoing 화면에 고정되어
    /// 첫 frame에 목적지가 flash되지 않음.
    @State private var animatedSlideID = 0
    /// popover close 시 최상단으로 reset — mid-scroll 재오픈 방지.
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    /// Customize "reset all" 확인 sheet 표시 여부 — sheet가 이 panel에 attach되어 버튼 클릭이
    /// popover를 닫는 outside click으로 오인되지 않음.
    @State private var isPresentingResetAllConfirm = false
    private static let outerPadding: CGFloat = 14
    private static let contentBottomGap: CGFloat = 12
    private static let footerHorizontalPadding: CGFloat = outerPadding
    private static let reorderSpace = "popoverReorderSpace"
    /// 두 density 공통의 단일 폭 — density 전환 시 popover 왼쪽 edge 고정.
    private static let popoverWidth: CGFloat = 320
    private static let topBarHeight: CGFloat = 44

    var body: some View {
        modeBody
            .frame(width: Self.popoverWidth)
            // panel이 콘텐츠에 auto-fit하므로 평시엔 no-op — 콘텐츠가 화면 cap을 넘으면 내부 scroll view가 overflow 처리.
            .frame(maxHeight: .infinity, alignment: .top)
            // 모든 콘텐츠 뒤의 page surface — 기본 opaque, Increase Transparency/egg에서는 clear로 backdrop 노출.
            .background(PopoverSurface())
            // `.animation(nil, ...)` 바깥의 body 루트에서 panel 높이 구동 — 높이가 slide의 spring에 함께 실림.
            .drivesPanelHeight(animatedHeight)
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .background(
                // Esc/Return은 화면을 한 단계씩 되돌리고 dashboard에서만 popover를 닫음 — 항상 consume해
                // bare Return이 popover를 닫지 못하게 보장.
                PopoverKeyReader(
                    onEscape: {
                        if let reorderLift, case .settingsAccountRow = reorderLift.payload {
                            self.reorderLift = nil
                            return true
                        }
                        // L2 detail → L1 → dashboard 순의 단계적 후퇴.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        guard layout.screen != .dashboard else { return false }
                        withAnimation(Motion.modeSwitch) { layout.screen = .dashboard }
                        return true
                    },
                    onReturn: {
                        // Esc와 동일하게 L2 → L1 → dashboard 단계 이동.
                        if layout.customizeProviderID != nil {
                            withAnimation(Motion.spring) { layout.customizeProviderID = nil }
                            return true
                        }
                        let target: PopoverScreen = layout.screen == .dashboard ? .customize : .dashboard
                        withAnimation(Motion.modeSwitch) { layout.screen = target }
                        return true
                    },
                    // ⌘,는 모든 화면에서 Settings 토글 — 여기서 consume해 Options 메뉴 항목의 ⌘, label과
                    // 이중 등록 충돌 방지.
                    onSettings: {
                        withAnimation(Motion.modeSwitch) {
                            layout.screen = layout.screen == .settings ? .dashboard : .settings
                        }
                        return true
                    },
                    // ⌘Z는 마지막 customization 단계 undo — monitor가 panel 소유와 텍스트 편집 여부를 이미
                    // 확인했으므로 항상 consume, undo 없음은 beep 없이 무시.
                    onUndo: {
                        guard layout.canUndo else { return true }
                        withAnimation(Motion.spring) { _ = layout.undo() }
                        return true
                    }
                )
            )
            // controller가 소유한 show/hide 신호를 재사용 — AppKit window notification으로 재발견하지 않음.
            .onChange(of: transparency.popoverShown) { _, shown in
                if shown {
                    // 재오픈: SwiftUI tree가 close를 넘어 살아남으므로 현재 화면 높이를 un-animated로 re-seed.
                    if let target = heightCoordinator.target(for: layout.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                } else {
                    resetTransientState()
                }
            }
            // 화면 전환이 drag 도중 리스트를 해체하면 `onEnded`가 오지 않으므로 lift를 여기서 정리.
            .onChange(of: layout.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            // L1 이탈 시 stale한 Reset All 확인 상태 drop — 복귀 시 fresh tap 없는 재표시 방지.
            .onChange(of: layout.screen == .customize && layout.customizeProviderID == nil) { _, isL1Visible in
                if !isL1Visible { isPresentingResetAllConfirm = false }
            }
            // 전환마다 outgoing에 고정(0) 후 다음 runloop tick에 spring — 같은 closure 안의 0→1 설정은
            // no-op이 되므로(SwiftUI는 마지막 commit 값에서 애니메이션) 한 tick 지연이 필수.
            .onChange(of: layout.screenSlideID) { _, id in
                guard id != 0 else { return }
                slideProgress = 0
                animatedSlideID = id
                let destination = layout.screen
                Task { @MainActor in
                    // slide와 높이를 하나의 spring으로 co-animate. 목적지가 미측정이고 높이가 0 sentinel이면
                    // morph 금지 — clamp된 0으로 morph 시 panel이 잘못 줄어드므로 completion/측정이 establish.
                    let coTarget: CGFloat? = heightCoordinator.target(for: destination)
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.spring, completionCriteria: .logicallyComplete) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        guard let target = heightCoordinator.target(for: layout.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target            // un-animated establish — 0에서 자라나지 않음
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.spring) { animatedHeight = target }
                        }
                    }
                }
            }
            // 화면 내 성장/축소는 같은 spring으로 re-target — establish는 slide 중에도 허용, 애니메이션
            // re-target은 slide 진행 중이면 전환 경로에 양보.
            .onChange(of: heightCoordinator.measuredIdeal[layout.screen]) { _, _ in
                guard let target = heightCoordinator.target(for: layout.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if !isSliding, abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.spring) { animatedHeight = target }
                }
            }
            // secret transparency code 감시 — 관찰만 하고 consume하지 않아 내비게이션/입력을 방해하지 않음.
            .background(TooMuchTransparencyKeyReader { transparency.toggleSecretCode() })
            // 모든 surface가 opaque base를 칠할지 behind-window backdrop으로 clear할지 결정.
            .environment(\.popoverSurfaceTreatment, transparency.surfaceTreatment)
            // easter egg 시각 효과(party/drunk) — overlay는 hit-test하지 않아 실행 중에도 컨트롤 조작 가능.
            .tooMuchTransparency(transparency.effectiveStyle)
            // egg 애니메이션 loop를 popover 표시 여부로 gate — `.tooMuchTransparency` 바깥이라 해당 layer까지 도달.
            // occlusion이 아닌 controller의 show/hide 신호 기준(Space 전환 중 일시 occlusion 오판 방지).
            .environment(\.popoverIsVisible, transparency.popoverShown)
    }

    private func resetTransientState() {
        // popover-close 경로의 backstop — 닫힌 popover는 hover-exit을 보내지 않으므로 잔존 tooltip/hover popover 정리.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        if layout.screen != .dashboard { layout.screen = .dashboard }
        reorderLift = nil
        layout.cancelDrag()
        // "Copied to clipboard" pill이 다음 open에 stale하게 재등장하는 것 방지.
        layout.clearShareConfirmation()
        layout.clearCustomizationNotice()
        // alert 도중 popover가 닫히면 확인 상태 drop — sheet의 stale 재등장 방지.
        isPresentingResetAllConfirm = false
        // 다음 open이 새 측정으로 un-animated re-establish하도록 0 sentinel로 reset.
        animatedHeight = 0
        didEstablishHeight = false
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// 화면들을 수평 pager로 구성 — 평시 1페이지, 전환 중 outgoing/incoming 두 페이지를 순수 offset으로 slide.
    /// `.transition` 대신 offset인 이유: opacity가 개입하면 `.quaternary` glass가 backdrop을 잃고 흰 flash 발생.
    private var modeBody: some View {
        let pages = slidePages
        return HStack(alignment: .top, spacing: 0) {
            ForEach(pages, id: \.self) { screen in
                screenView(screen)
                    .frame(width: Self.popoverWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: Self.popoverWidth, alignment: .leading)
        .offset(x: slideOffset(pages))
        .animation(nil, value: layout.screenSlideID)
    }

    /// `layout.screen` 변경 시점부터 slide가 incoming 화면에 도달할 때까지 true.
    private var isSliding: Bool {
        layout.screenSlideID != 0
            && (layout.screenSlideID != animatedSlideID || slideProgress < 1)
    }

    /// 평시엔 현재 화면 1페이지, 전환 중엔 두 화면을 좌→우 rank 순으로 나열.
    private var slidePages: [PopoverScreen] {
        guard isSliding else { return [layout.screen] }
        let from = layout.screenSlideFrom
        let to = layout.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    /// outgoing(0)→incoming(1)을 배치하는 수평 offset — 애니메이션 시작 전에는 outgoing에 고정되어
    /// 첫 frame에 목적지가 flash되지 않음.
    private func slideOffset(_ pages: [PopoverScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let fromOffset = -CGFloat(pages.firstIndex(of: layout.screenSlideFrom) ?? 0) * Self.popoverWidth
        let toOffset = -CGFloat(pages.firstIndex(of: layout.screen) ?? 0) * Self.popoverWidth
        let progress = animatedSlideID == layout.screenSlideID ? slideProgress : 0
        return fromOffset + progress * (toOffset - fromOffset)
    }

    /// 한 화면 구성: scroll body + 고정 chrome. chrome은 per-page `screen`이 아닌 목적지(`layout.screen`) 기준 —
    /// 전환 중 두 페이지가 동일한 chrome을 그려 콘텐츠만 slide하는 것으로 보임.
    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        scrollBody(for: screen)
            // scroll 콘텐츠의 intrinsic 높이를 화면별 ideal로 합산 — per-page `screen` 기준으로 각자 측정.
            .onPreferenceChange(ScrollContentHeightKey.self) { height in
                heightCoordinator.setScrollContent(height, for: screen)
            }
            .softTopScrollEdge()
            .softBottomScrollEdge()
            .pinnedTopBar(spacing: 0) {
                PopoverTopBar(
                    layout: layout,
                    height: Self.topBarHeight,
                    horizontalPadding: Self.footerHorizontalPadding,
                    onResetAll: {
                        layout.resetToDefault()
                        container.reseedEnabledProviders()
                    },
                    isPresentingResetAllConfirm: $isPresentingResetAllConfirm
                )
            }
            .pinnedFooter(spacing: 0) {
                PopoverFooter(
                    screen: layout.screen,
                    layout: layout,
                    dataStore: dataStore,
                    horizontalPadding: Self.footerHorizontalPadding
                ) { screen, height in
                    heightCoordinator.setFooter(height, for: screen)
                }
            }
    }

    /// chrome 없는 화면별 scroll 콘텐츠 — 전환 시 실제로 slide되는 부분.
    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                container: container,
                layout: layout,
                updater: updater,
                reorderSpaceName: Self.reorderSpace,
                horizontalPadding: Self.outerPadding,
                bottomGap: Self.contentBottomGap,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .customize:
            CustomizeView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen(reorderSpaceName: Self.reorderSpace, reorderLift: $reorderLift)
        }
    }

}

/// 모든 콘텐츠 뒤에 칠하는 popover의 opaque backdrop tray — AppKit panel backdrop(`Theme.trayNSColor`)과 일치.
/// hit-test하지 않아 위 콘텐츠의 클릭을 가로채지 않음.
private struct PopoverSurface: View {
    @Environment(\.popoverSurfaceTreatment) private var treatment

    var body: some View {
        Group {
            switch treatment {
            case .opaque:
                Theme.traySurface
            case .translucent:
                // behind-window vibrancy backdrop(blurred desktop/party gradient)이 비치도록 clear.
                Color.clear
            }
        }
        .allowsHitTesting(false)
    }
}
