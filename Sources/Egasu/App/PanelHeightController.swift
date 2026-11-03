import AppKit

/// 메뉴 바 panel의 배치와 content 기반 높이 변경 담당.
/// panel 생성·show/hide는 status-item controller 소유 — 이 타입은 SwiftUI–AppKit 높이 경계만 담당.
@MainActor
final class PanelHeightController {
    static let panelWidth: CGFloat = 320
    static let defaultHeight: CGFloat = 800

    private let panel: MenuBarPanel
    private let currentScreen: () -> PopoverScreen
    private let defaults: UserDefaults

    private var anchorScreen: NSScreen?
    private var anchorTopLeft: NSPoint?
    private var morphSettleTask: Task<Void, Never>?
    private(set) var isMorphing = false

    init(
        panel: MenuBarPanel,
        defaults: UserDefaults = .standard,
        currentScreen: @escaping () -> PopoverScreen
    ) {
        self.panel = panel
        self.defaults = defaults
        self.currentScreen = currentScreen
    }

    /// SwiftUI가 쓰는 두 callback 설치: 애니메이션 frame 적용, 표시 가능 높이로 clamp.
    func installBridge() {
        MenuBarPopover.applyHeight = { [weak self] height in
            self?.applyMorphHeight(height)
        }
        MenuBarPopover.clampHeight = { [weak self] rawHeight in
            self?.clampedHeight(rawHeight) ?? rawHeight
        }
    }

    /// 이전 세션 정리, display 캡처, 기억된 높이로 open.
    /// SwiftUI가 popover 표시를 인지하기 전 실행 필수 — 그 신호가 즉시 clamp hook에 실제 최대 높이 질의.
    func prepareForOpening(below buttonRect: NSRect) {
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()

        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        anchorScreen = screen
        let topLeft = PanelGeometry.clampedTopLeft(
            below: buttonRect,
            width: Self.panelWidth,
            visibleFrame: screen?.visibleFrame
        )
        anchorTopLeft = topLeft

        let remembered = loadHeight(for: currentScreen()) ?? Self.defaultHeight
        let height = clampedHeight(remembered)
        panel.setFrame(
            PanelGeometry.frame(topLeft: topLeft, width: Self.panelWidth, height: height),
            display: false
        )
        panel.invalidateShadow()
    }

    /// screen 전환·panel order-out 전 높이 저장.
    func saveBeforeClosing() {
        guard panel.isVisible else { return }
        saveHeight(panel.frame.height, for: currentScreen())
    }

    /// panel order-out 후 opening 세션 상태 초기화.
    func finishClosing() {
        anchorTopLeft = nil
        anchorScreen = nil
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()
    }

    private func applyMorphHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1, panel.isVisible else { return }
        guard let anchorTopLeft else {
            AppLog.error(.statusItem, "Morph height while visible but no anchor; frame not applied")
            return
        }
        let height = clampedHeight(rawHeight)
        guard abs(panel.frame.height - height) > 1 else { return }
        panel.setFrame(
            PanelGeometry.frame(topLeft: anchorTopLeft, width: Self.panelWidth, height: height),
            display: false
        )
        panel.invalidateShadow()
        isMorphing = true
        scheduleMorphSettle()
    }

    private func scheduleMorphSettle() {
        morphSettleTask?.cancel()
        morphSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.panel.isVisible else { return }
            self.isMorphing = false
            self.saveHeight(self.panel.frame.height, for: self.currentScreen())
        }
    }

    private func clampedHeight(_ rawHeight: CGFloat) -> CGFloat {
        PanelGeometry.clampedHeight(rawHeight, maximum: maximumHeight())
    }

    private func maximumHeight() -> CGFloat {
        guard let anchorTopLeft, let visibleFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultHeight
        }
        return PanelGeometry.maximumHeight(topLeft: anchorTopLeft, visibleFrame: visibleFrame)
    }

    private func loadHeight(for screen: PopoverScreen) -> CGFloat? {
        let value = defaults.double(forKey: Self.heightKey(for: screen))
        return value > 0 ? CGFloat(value) : nil
    }

    private func saveHeight(_ height: CGFloat, for screen: PopoverScreen) {
        defaults.set(Double(height), forKey: Self.heightKey(for: screen))
    }

    private static func heightKey(for screen: PopoverScreen) -> String {
        switch screen {
        case .dashboard: "openusage.panel.height.dashboard"
        case .customize: "openusage.panel.height.customize"
        case .settings: "openusage.panel.height.settings"
        }
    }
}

/// 순수 panel geometry — window 없이 display clamp 테스트 가능하도록 분리.
enum PanelGeometry {
    static let topGap: CGFloat = 4
    static let screenMargin: CGFloat = 8
    static let minimumHeight: CGFloat = 200

    static func clampedTopLeft(below buttonRect: NSRect, width: CGFloat, visibleFrame: NSRect?) -> NSPoint {
        var x = buttonRect.minX
        if let visibleFrame {
            x = min(
                max(x, visibleFrame.minX + screenMargin),
                visibleFrame.maxX - width - screenMargin
            )
        }
        return NSPoint(x: x, y: buttonRect.minY - topGap)
    }

    static func maximumHeight(topLeft: NSPoint, visibleFrame: NSRect) -> CGFloat {
        let roomBelowAnchor = topLeft.y - visibleFrame.minY - screenMargin
        let aestheticCap = floor(visibleFrame.height * 0.85)
        return max(1, min(roomBelowAnchor, aestheticCap))
    }

    static func clampedHeight(_ rawHeight: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(rawHeight, minimumHeight), maximum)
    }

    static func frame(topLeft: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        NSRect(
            origin: NSPoint(x: topLeft.x, y: topLeft.y - height),
            size: NSSize(width: width, height: height)
        )
    }
}
