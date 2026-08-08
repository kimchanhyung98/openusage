import AppKit

/// 메뉴 바 panel을 dismiss하는 local·global mouse monitor 소유.
@MainActor
final class PanelOutsideClickMonitor {
    private let panel: MenuBarPanel
    private let statusItem: NSStatusItem
    private let isMorphing: () -> Bool
    private let onInsidePanelClick: () -> Void
    private let onDismiss: () -> Void
    private var monitors: [Any] = []

    init(
        panel: MenuBarPanel,
        statusItem: NSStatusItem,
        isMorphing: @escaping () -> Bool,
        onInsidePanelClick: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.panel = panel
        self.statusItem = statusItem
        self.isMorphing = isMorphing
        self.onInsidePanelClick = onInsidePanelClick
        self.onDismiss = onDismiss
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // NSEvent는 non-Sendable — main actor 복귀 전 작은 값만 복사.
            let windowID = event.window.map(ObjectIdentifier.init)
            let windowTypeName = event.window.map { String(describing: type(of: $0)) }
            MainActor.assumeIsolated {
                self?.handleClick(
                    windowID: windowID,
                    windowTypeName: windowTypeName,
                    screenPoint: NSEvent.mouseLocation
                )
            }
            return event
        }) {
            monitors.append(local)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            // 위치는 즉시 읽기 — main-actor task 실행 전 포인터 이동 가능.
            let screenPoint = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                self?.handleClick(windowID: nil, windowTypeName: nil, screenPoint: screenPoint)
            }
        }) {
            monitors.append(global)
        }
    }

    func stop() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors = []
    }

    private func handleClick(
        windowID: ObjectIdentifier?,
        windowTypeName: String?,
        screenPoint: NSPoint
    ) {
        let isInsidePanel = panel.frame.contains(screenPoint)
        let hasWindowContext = windowID != nil && windowTypeName != nil
        let buttonWindowID = statusItem.button?.window.map(ObjectIdentifier.init)
        let context = PanelOutsideClickContext(
            isMorphing: isMorphing(),
            hasAttachedSheet: panel.attachedSheet != nil,
            isOnStatusButton: isOnStatusButton(screenPoint),
            isInsidePanel: isInsidePanel,
            isPanelWindow: hasWindowContext && windowID == ObjectIdentifier(panel),
            isStatusItemWindow: hasWindowContext && windowID == buttonWindowID,
            eventWindowTypeName: hasWindowContext ? windowTypeName : nil
        )

        if PanelOutsideClickPolicy.shouldKeepOpen(context) {
            if isInsidePanel { onInsidePanelClick() }
            return
        }
        onDismiss()
    }

    private func isOnStatusButton(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let buttonWindow = button.window else { return false }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        return PanelOutsideClickPolicy.pointHitsStatusButton(
            screenPoint,
            buttonFrame: buttonFrame,
            screenTop: buttonWindow.screen?.frame.maxY
        )
    }
}

struct PanelOutsideClickContext {
    var isMorphing = false
    var hasAttachedSheet = false
    var isOnStatusButton = false
    var isInsidePanel = false
    var isPanelWindow = false
    var isStatusItemWindow = false
    var eventWindowTypeName: String?
}

enum PanelOutsideClickPolicy {
    static func shouldKeepOpen(_ context: PanelOutsideClickContext) -> Bool {
        context.isMorphing
            || context.hasAttachedSheet
            || context.isOnStatusButton
            || context.isInsidePanel
            || context.isPanelWindow
            || context.isStatusItemWindow
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("menu") == true
            // hover popover(`_NSPopoverWindow`)는 panel frame 밖의 자체 window — outside click 오판 시 내부 컨트롤의 mouse-up 전에 panel 해제.
            || context.eventWindowTypeName?.localizedCaseInsensitiveContains("popover") == true
    }

    /// status-button hit test. 화면 최상단에 붙은 클릭도 버튼으로 판정 필수 (#1008) —
    /// hit zone을 버튼 상단에서 screen top까지 확장, max edge 포함 비교. macOS의 클릭 라우팅과 불일치 시 dismiss가 버튼 toggle과 race.
    static func pointHitsStatusButton(_ point: NSPoint, buttonFrame: NSRect, screenTop: CGFloat?) -> Bool {
        guard !buttonFrame.isEmpty else { return false }
        let top = max(buttonFrame.maxY, screenTop ?? buttonFrame.maxY)
        return point.x >= buttonFrame.minX && point.x <= buttonFrame.maxX
            && point.y >= buttonFrame.minY && point.y <= top
    }
}
