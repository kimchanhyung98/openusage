import SwiftUI
import AppKit

/// popover panel이 key window인 동안 secret code(↑ ↑ ↓ ↓ ← → ← → B A) 감지 후 `onMatched` 호출.
/// `PopoverKeyReader`의 의도적 sibling — navigation monitor에 egg 관심사를 싣지 않음.
/// key를 절대 소비하지 않는 관찰 전용 monitor라 일반 타이핑·navigation에 영향 없음.
struct TooMuchTransparencyKeyReader: NSViewRepresentable {
    /// 시퀀스 완성 시 호출 — 재입력하면 다시 발화(재입력으로 토글 off).
    var onMatched: @MainActor () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onMatched = onMatched
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onMatched = onMatched
    }

    final class MonitorView: NSView {
        var onMatched: (@MainActor () -> Void)?
        private var monitor: Any?
        private var matcher = SecretCodeMatcher()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            matcher.reset()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // code는 bare key 입력 — auto-repeat와 ⌘/⌃/⌥ chord 무시(Shift는 허용, `charactersIgnoringModifiers`가 대소문자 정규화).
                guard !event.isARepeat,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                    return event
                }
                let keyCode = event.keyCode
                let characters = event.charactersIgnoringModifiers
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isVisible else { return }
                    // popover가 keystroke를 소유하고 텍스트 필드/shortcut recorder가 캡처 중이 아닐 때만 동작.
                    guard PopoverKeyReader.keyTargetsPopover(
                        eventWindowID: eventWindowID,
                        popoverWindowID: ObjectIdentifier(window)
                    ), !(window.firstResponder is NSText), !ShortcutRecorderField.isRecordingActive else {
                        return
                    }
                    guard let token = Self.token(keyCode: keyCode, characters: characters) else {
                        // code에 속하지 않는 실제 key는 진행 중인 run을 끊음.
                        self.matcher.reset()
                        return
                    }
                    if self.matcher.accept(token) {
                        self.onMatched?()
                    }
                }
                // 절대 소비하지 않음 — egg는 관찰만 함.
                return event
            }
        }

        // 정리는 `viewDidMoveToWindow(nil)`에서 수행 — Swift 6에서 nonisolated `deinit`이 non-Sendable monitor token에 접근하지 않도록 함.

        /// 화살표는 virtual key code(레이아웃 불변), A/B는 문자로 매칭 — A/B를 `keyCode`로 매칭하면 non-QWERTY 레이아웃에서 오동작.
        private static func token(keyCode: UInt16, characters: String?) -> SecretCodeKey? {
            switch keyCode {
            case 126: return .up
            case 125: return .down
            case 123: return .left
            case 124: return .right
            default: break
            }
            switch characters?.lowercased() {
            case "a": return .a
            case "b": return .b
            default: return nil
            }
        }
    }
}
