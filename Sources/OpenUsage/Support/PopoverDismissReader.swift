import SwiftUI
import AppKit

/// local key monitor로 popover의 bare navigation key 처리 — SwiftUI `.keyboardShortcut`은 popover가 key window일 때만 동작해 신뢰 불가.
/// Esc는 `onEscape`가 먼저 거부권 행사 후 `MenuBarPopover.dismiss`로 닫기(status-item 클릭과 같은 경로);
/// Return은 Customize 진입/복귀를 처리하며 여기서 소비되어 popover dismiss로 흘러가지 않음.
struct PopoverKeyReader: NSViewRepresentable {
    /// Esc에서 최우선 호출. in-popover에서 처리했으면 `true`(닫히지 않음); `false`면 popover dismiss.
    var onEscape: @MainActor () -> Bool = { false }
    /// 무수식 Return에서 호출. `true`면 소비(예: Customize 토글); `false`면 focus된 컨트롤로 fall through.
    var onReturn: @MainActor () -> Bool = { false }
    /// ⌘,(Settings)에서 호출 — 상시 monitor라 모든 화면에서 동작.
    /// Options 메뉴의 ⌘,는 라벨일 뿐 — 메뉴가 열려 있으면 메뉴 항목이, 닫혀 있으면 이 monitor가 처리해 이중 발화 없음.
    var onSettings: @MainActor () -> Bool = { false }
    /// 무수식 ⌘Z(undo)에서 호출. monitor가 panel의 keystroke 소유와 텍스트 편집 부재를 이미 확인한 뒤이므로
    /// undo 실행 여부와 무관하게 `true` 반환·소비 권장 — `false`는 빈 undo에서 AppKit beep만 유발.
    var onUndo: @MainActor () -> Bool = { false }

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onEscape = onEscape
        view.onReturn = onReturn
        view.onSettings = onSettings
        view.onUndo = onUndo
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.onEscape = onEscape
        view.onReturn = onReturn
        view.onSettings = onSettings
        view.onUndo = onUndo
    }

    /// bare-key keyDown의 popover 소유 여부 — event의 key window가 panel 자체여야 함.
    /// 외부 key window(About 패널, tracking `NSMenu`)나 key window 부재는 popover 소유가 아니므로 Esc/Return이 가로채지 않음.
    // `nonisolated`: Sendable `ObjectIdentifier` 비교뿐 — struct의 암묵적 @MainActor가 테스트 등 non-MainActor 호출을 막지 않도록 함.
    nonisolated static func keyTargetsPopover(eventWindowID: ObjectIdentifier?, popoverWindowID: ObjectIdentifier) -> Bool {
        eventWindowID == popoverWindowID
    }

    final class MonitorView: NSView {
        var onEscape: (@MainActor () -> Bool)?
        var onReturn: (@MainActor () -> Bool)?
        var onSettings: (@MainActor () -> Bool)?
        var onUndo: (@MainActor () -> Bool)?
        private var monitor: Any?
        private static let escapeKeyCode: UInt16 = 53
        private static let returnKeyCode: UInt16 = 36
        private static let commaKeyCode: UInt16 = 43
        private static let zKeyCode: UInt16 = 6

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let keyCode = event.keyCode
                guard keyCode == MonitorView.escapeKeyCode
                    || keyCode == MonitorView.returnKeyCode
                    || keyCode == MonitorView.commaKeyCode
                    || keyCode == MonitorView.zKeyCode else {
                    return event
                }
                let isReturn = keyCode == MonitorView.returnKeyCode
                let isComma = keyCode == MonitorView.commaKeyCode
                let isUndo = keyCode == MonitorView.zKeyCode
                // 무수식 Return만 navigation; ⌘⏎, ⌥⏎ 등은 다른 컨트롤 소유.
                if isReturn,
                   !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                    return event
                }
                // 순수 ⌘,만 navigation; bare comma(타이핑)나 ⌥⌘, 등은 다른 곳 소유.
                if isComma,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]) != [.command] {
                    return event
                }
                // 순수 ⌘Z만 undo; bare z(타이핑)나 ⇧⌘Z(redo)는 다른 곳 소유.
                if isUndo,
                   event.modifierFlags.intersection([.command, .option, .control, .shift]) != [.command] {
                    return event
                }
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    // popover가 on-screen일 때만 동작 — SwiftUI tree와 monitor는 close 후에도 살아 있을 수 있음.
                    guard let self, let window = self.window, window.isVisible else { return false }
                    // key가 popover를 대상으로 해야 함 — 메뉴/About 패널이 focus를 가진 동안의 key는 무시(`keyTargetsPopover` 참고).
                    guard PopoverKeyReader.keyTargetsPopover(
                        eventWindowID: eventWindowID,
                        popoverWindowID: ObjectIdentifier(window)
                    ) else { return false }
                    // 텍스트 컨트롤 편집 중이거나 shortcut recorder 캡처 중이면 key는 그쪽 소유.
                    if window.firstResponder is NSText || ShortcutRecorderField.isRecordingActive {
                        return false
                    }
                    if isComma {
                        return self.onSettings?() ?? false
                    }
                    if isUndo {
                        return self.onUndo?() ?? false
                    }
                    if isReturn {
                        return self.onReturn?() ?? false
                    }
                    if self.onEscape?() == true {
                        return true
                    }
                    MenuBarPopover.dismiss(fallback: window)
                    return true
                }
                return consumed ? nil : event
            }
        }
    }
}

/// popover 내부 view가 소유자를 모른 채 popover를 제어하게 하는 진입점.
@MainActor
enum MenuBarPopover {
    /// `StatusItemController`가 launch 시 설치 — status-item 클릭과 같은 경로로 popover 닫기.
    static var dismissHandler: (() -> Void)?

    /// `StatusItemController`가 launch 시 설치 — popover 열기(예: pace 알림 배너 탭).
    static var showHandler: (() -> Void)?

    /// auto-resize 브리지 — "single clock". SwiftUI가 애니메이션 높이를 소유하고 AppKit panel은 수동 follower.
    /// `applyHeight`는 SwiftUI layout pass 내부에서 호출되므로 main queue hop 필수(`setFrame` 재진입이 layout 재귀 유발);
    /// `clampHeight`는 SwiftUI 목표를 panel의 [min, screen-max] 범위로 clamp해 spring이 정확히 frame에 안착.
    static var applyHeight: ((CGFloat) -> Void)?
    static var clampHeight: ((CGFloat) -> CGFloat)?

    /// popover 닫기. handler 미설치 시(배선 버그) 지정 window의 order-out으로 fallback.
    static func dismiss(fallback window: NSWindow?) {
        if let dismissHandler {
            dismissHandler()
        } else {
            window?.orderOut(nil)
        }
    }

    static func show() {
        showHandler?()
    }
}
