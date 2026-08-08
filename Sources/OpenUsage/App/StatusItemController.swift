import AppKit
import KeyboardShortcuts
import SwiftUI

/// dashboard의 host window: key가 될 수 있는 borderless non-activating panel.
/// `NSPopover`는 앱 활성 상태에서만 key인데 `LSUIElement` 앱 활성화는 비동기·거부 가능 — 첫 키 입력 유실.
/// `canBecomeKey`가 true인 `.nonactivatingPanel`은 앱 활성화 없이 order front 즉시 key — 키보드 입력이 첫 시도에 동작.
final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 메뉴 바 status item과 dashboard panel 소유.
/// 의도적으로 SwiftUI `MenuBarExtra` 미사용 — `.window` panel은 텍스트 입력용 key window 불가, programmatic 표시 API 부재.
@MainActor
final class StatusItemController: NSObject {
    private let container: AppContainer
    private let statusItem: NSStatusItem
    /// 메뉴 바 strip 렌더 loop 소유. apply closure가 `NSStatusItem`을 직접 캡처 (controller 비보유) — plain `let` 가능.
    private let imageUpdater: StatusItemImageUpdater
    private let panel: MenuBarPanel
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        onInsidePanelClick: { [weak self] in self?.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private let hostingController: NSHostingController<AnyView>
    /// panel backdrop: 기본 opaque tray, 투명 style 시 behind-window vibrancy로 전환. 1회 구성 후 toggle — style observer와 race 없음.
    private let backdrop = PopoverBackdropView(cornerRadius: StatusItemController.cornerRadius)
    /// appearance-change observer token — 문서화된 제거 패턴 준수용 보유.
    private var appearanceObserver: NSObjectProtocol?
    private static let cornerRadius: CGFloat = 13

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        // `self`가 아닌 status item 캡처 — retain cycle 없음; button은 apply마다 lazy resolve라 미구성 상태 무해.
        self.imageUpdater = StatusItemImageUpdater(container: container) { image in
            statusItem.button?.image = image
        }

        let hosting = NSHostingController(
            rootView: AnyView(
                DashboardView()
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(container.transparency)
                    .environment(updater)
                    .environment(\.codexResetClaim, container.codexResetClaim)
            )
        )
        // SwiftUI가 screen별 측정으로 panel 높이 주도; 높이가 화면 한계에 닿을 때만 scroll.
        self.hostingController = hosting

        let panel = MenuBarPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: PanelHeightController.panelWidth,
                height: PanelHeightController.defaultHeight
            ),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        self.panel = panel
        self.heightController = PanelHeightController(panel: panel) { container.layout.screen }

        super.init()

        configurePanel()
        configureStatusItem()
        imageUpdater.update()
        applyTransparency()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        // 1회 등록 — controller는 앱 수명 전체 유지.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // dashboard의 Esc는 status-item 클릭과 동일 경로로 dismiss.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.hidePanel()
        }
        MenuBarPopover.showHandler = { [weak self] in
            self?.container.layout.screen = .dashboard
            self?.showPopover()
        }

        heightController.installBridge()

        AppLog.info(.statusItem, "Status item ready (button: \(self.statusItem.button != nil), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))")
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // theme override 고정 (System은 nil) — 메뉴 바 appearance 우선 방지; `appearanceObserver`가 live 추적.
        panel.appearance = AppearanceSetting.current.nsAppearance

        let container = NSView()

        // backdrop은 window 전체를 채움 — screen 전환 resize의 투명 strip 노출 방지, SwiftUI 미도색 영역도 backdrop 표시.
        // opaque tray 색은 SwiftUI tray(`DashboardView.PopoverSurface`)와 동일한 `Theme.trayNSColor`.
        let host = hostingController.view
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // 높이 변경 매 step마다 SwiftUI content 재도색 — layer cache stretch 방지로 morph 중 카드 안정.
        host.layerContentsRedrawPolicy = .duringViewResize
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true

        container.addSubview(backdrop)
        container.addSubview(host, positioned: .above, relativeTo: backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // container VC의 child로 hosting controller 배치 — SwiftUI에 올바른 view-controller 계층 제공.
        let rootVC = NSViewController()
        rootVC.view = container
        rootVC.addChild(hostingController)
        panel.contentViewController = rootVC
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        // 좌클릭은 popover toggle, 우클릭/control-클릭은 context menu — 모두 `statusButtonClicked`에서 분기.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Transparency

    /// 첫 적용 이후 true — 이후 style 변경만 애니메이션 (첫 적용은 fade-in 금지).
    private var hasAppliedTransparency = false

    /// resolve된 투명 style을 panel에 적용하고 다음 변경에 re-arm (`withObservationTracking`의 `onChange`는 one-shot).
    /// store의 `effectiveStyle`이 토글·egg·시스템 접근성 flag를 통합 — 어느 것이 변해도 발화.
    /// 런치 이후 변경은 window alpha와 backdrop crossfade가 SwiftUI 쪽과 동일한 한 group으로 ease.
    private func applyTransparency() {
        let style = withObservationTracking {
            container.transparency.effectiveStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyTransparency()
            }
        }
        let mode: PopoverBackdropView.Mode = style.surfaceTreatment == .opaque ? .opaque : .translucent
        if hasAppliedTransparency {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.55
                context.allowsImplicitAnimation = true
                panel.animator().alphaValue = style.windowAlpha
                backdrop.setMode(mode, animated: true)
            }
        } else {
            hasAppliedTransparency = true
            panel.alphaValue = style.windowAlpha
            backdrop.setMode(mode, animated: false)
        }
        // shadow는 애니메이션 불가 — 직접 설정 (crossfade가 변화 은폐).
        panel.hasShadow = style.wantsShadow
        panel.invalidateShadow()
    }

    // MARK: - Show / hide

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isContextClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// status item 우클릭/control-클릭: popover footer Options 메뉴를 미러링한 native menu.
    /// `performClick` 동안만 `statusItem.menu` 할당 — 해제로 좌클릭 toggle 복원.
    private func showContextMenu() {
        // 열린 panel 먼저 닫기 — 잔여 highlight·outside-click monitor가 menu의 modal tracking과 race 방지.
        if panel.isVisible { hidePanel() }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Settings", systemSymbol: "gearshape", keyEquivalent: ",") { [weak self] in
            self?.openSettings()
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Quit OpenUsage", systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Settings 화면으로 dashboard popover open — Settings는 in-popover 화면. panel 표시 전 screen 설정으로 Settings 크기로 open.
    private func openSettings() {
        container.layout.screen = .settings
        if !panel.isVisible {
            showPanel()
        }
    }

    func togglePopover() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// 이미 표시 중이면 닫지 않고 전면으로 — 외부 트리거(pace 알림 탭)용.
    func showPopover() {
        if panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            statusItem.button?.highlight(true)
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // visibility 신호 변경 전 display 기록 — 신호가 즉시 높이 clamp 유발, anchor 없으면 고정 추정치로 fallback.
        heightController.prepareForOpening(below: buttonRectOnScreen)
        // layout 전에 popover on-screen 표시 — egg 애니메이션의 `TimelineView` clock이 첫 frame에 mount.
        container.transparency.setPopoverShown(true)

        // content 선-layout — 첫 frame flash 없이 정확한 크기로 open.
        hostingController.view.layoutSubtreeIfNeeded()

        // 앱 활성화 없이 key — activation race 없이 첫 시도에 키 입력 수신.
        panel.makeKeyAndOrderFront(nil)
        // Keyboard Navigation 켜짐 시 AppKit이 첫 컨트롤 auto-focus — stray focus ring 제거 (키보드 nav는 local monitor 기반이라 유지).
        clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        // SwiftUI tree는 `orderOut` 후에도 생존 — hover-exit 없는 tooltip·hover popover가 화면에 고아로 남지 않도록 여기서 dismiss.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        // keyboard focus도 동일 생존 문제 — 닫을 때 해제해 재오픈 시 stray focus ring 방지.
        clearStrayFocus()
        // 닫히는 screen이 유효한 동안 저장 — authoritative SwiftUI close reset은 이후 실행.
        heightController.saveBeforeClosing()
        // on-screen flag 해제 — egg의 `TimelineView` clock unmount (숨김 중 CPU 0). `orderOut`과 동기로 flip되는 authoritative hide 신호.
        container.transparency.setPopoverShown(false)
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
    }

    /// panel 내부 keyboard focus 해제 — 클릭된 plain-style 컨트롤의 focus ring 잔류 방지.
    /// live 텍스트 필드/shortcut recorder는 예외 — 사용자가 의도한 focus (`PopoverKeyReader`의 `NSText` guard와 동일 사유).
    private func clearStrayFocus() {
        guard !ShortcutRecorderField.isRecordingActive,
              !(panel.firstResponder is NSText) else { return }
        panel.makeFirstResponder(nil)
    }

}
