import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// KeyboardShortcuts 스토어 기반 클릭-녹화 단축키 필드.
/// `KeyboardShortcuts.Recorder` 대체 — first responder 포커스가 메뉴바 팝오버(macOS 26+)에서 미동작.
/// 녹화는 로컬 key-event monitor 사용, 저장·글로벌 hotkey는 라이브러리 유지.
struct ShortcutRecorderField: View {
    let name: KeyboardShortcuts.Name

    /// `EscapeToCloseReader`가 참조 — 녹화 중 Esc는 recorder(취소) 소유, 팝오버 내비게이션 이중 처리 방지.
    @MainActor static private(set) var isRecordingActive = false

    @State private var isRecording = false
    @State private var keyMonitor: Any?
    /// `setShortcut` 후 chip 재렌더용 (라이브러리 스토어는 비관찰).
    @State private var currentShortcut: KeyboardShortcuts.Shortcut?
    /// 호스팅 팝오버 window — 녹화 시작 시 key 승격으로 로컬 monitor에 이벤트 도달 보장.
    @State private var hostWindow: NSWindow?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                chipContent
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quinary)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                lineWidth: isRecording ? 1.5 : 1
                            )
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isRecording, currentShortcut != nil {
                Button(action: clear) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .hoverTooltip("Clear Shortcut")
                .accessibilityLabel("Clear Shortcut")
            }
        }
        .onAppear {
            currentShortcut = KeyboardShortcuts.getShortcut(for: name)
        }
        .background(HostWindowReader(window: $hostWindow))
        // 녹화 중 팝오버 닫힘·화면 전환 대응
        .onDisappear {
            stopRecording()
        }
    }

    @ViewBuilder
    private var chipContent: some View {
        if isRecording {
            Text("Type Shortcut…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if let currentShortcut {
            Text(currentShortcut.description)
                .font(.system(.callout, design: .monospaced))
        } else {
            Text("Record Shortcut")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func clear() {
        KeyboardShortcuts.setShortcut(nil, for: name)
        currentShortcut = nil
    }

    private func startRecording() {
        stopRecording()
        // monitor 없이는 녹화 세션 불가 — 상태 변경 전 중단
        guard let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            MainActor.assumeIsolated {
                handleRecorded(event)
            }
            return nil
        }) else {
            NSSound.beep()
            return
        }
        keyMonitor = monitor
        isRecording = true
        Self.isRecordingActive = true
        NSApp.activate(ignoringOtherApps: true)
        hostWindow?.makeKey()
        // 녹화 대상 콤보가 현재 hotkey일 수 있음 — 입력이 팝오버를 토글하지 않도록 비활성
        KeyboardShortcuts.disable(name)
    }

    private func handleRecorded(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            stopRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete), event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            clear()
            stopRecording()
            return
        }
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event), isValid(shortcut) else {
            NSSound.beep()
            return
        }
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        currentShortcut = shortcut
        stopRecording()
    }

    /// 글로벌 hotkey는 실제 modifier 필수 — 일반 키(또는 shift 단독)는 타이핑 하이재킹.
    private func isValid(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        !shortcut.modifiers.intersection([.command, .option, .control]).isEmpty
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        Self.isRecordingActive = false
        KeyboardShortcuts.enable(name)
    }
}

/// 뷰의 호스팅 window 보고 — 녹화 시 key 승격용.
private struct HostWindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindowChange = { window = $0 }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WindowReportingView)?.onWindowChange = { window = $0 }
    }

    final class WindowReportingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // 이동을 유발한 SwiftUI 업데이트 이후로 지연
            DispatchQueue.main.async { [weak self] in
                self?.onWindowChange?(window)
            }
        }
    }
}
