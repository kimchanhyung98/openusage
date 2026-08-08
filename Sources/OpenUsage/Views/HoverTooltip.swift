import AppKit
import SwiftUI

/// Native `.help()`처럼 동작하되 delay를 직접 제어하고 hover 대상 바로 위에 anchor되는 tooltip — `.hoverTooltip(_:)`로 사용.
/// SwiftUI overlay가 아닌 별도의 borderless·non-activating·click-through `NSPanel`에 렌더링 — popover 창에 clip되지 않고,
/// key가 되지 않아 transient popover를 dismiss하지 않음. level은 popover(`.popUpMenu`)보다 한 단계 위(#696).
/// popover close 시 `HoverTooltips.dismissAll()`이 잔존 tooltip 정리.

extension View {
    /// 짧은 delay 후 hover 대상 위에 `text` 표시 — `nil`/빈 문자열은 no tooltip, 텍스트는 accessibility hint로도 노출.
    func hoverTooltip(_ text: String?) -> some View {
        modifier(HoverTooltipModifier(text: text))
    }
}

/// 대상별 중첩 깊이 — hover가 컨테이너와 자식에 동시에 걸리면 더 깊은 쪽의 tooltip이 우선.
private struct TooltipDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

private extension EnvironmentValues {
    var tooltipDepth: Int {
        get { self[TooltipDepthKey.self] }
        set { self[TooltipDepthKey.self] = newValue }
    }
}

/// subtree의 모든 `hoverTooltip`을 no-op으로 전환 — share-card export용: `ImageRenderer`가 AppKit anchor를
/// placeholder로 rasterize하는 문제 회피.
private struct TooltipsDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var hoverTooltipsDisabled: Bool {
        get { self[TooltipsDisabledKey.self] }
        set { self[TooltipsDisabledKey.self] = newValue }
    }
}

/// hover 대상의 backing `NSView`에 대한 weak handle — presenter가 show 시점에 lazy하게 screen rect로 해석.
@MainActor
private final class TooltipAnchor {
    weak var view: NSView?
    nonisolated init() {}

    /// Cocoa screen 좌표의 대상 frame — view가 사라졌거나 windowless면 `nil`.
    var screenRect: NSRect? {
        guard let view, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

/// 자신의 `NSView`를 anchor에 넘기는 투명 background view — hit-test 투과라 hover/클릭을 삼키지 않음.
private struct TooltipAnchorView: NSViewRepresentable {
    let anchor: TooltipAnchor

    private final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private struct HoverTooltipModifier: ViewModifier {
    let text: String?
    @Environment(\.tooltipDepth) private var depth
    @Environment(\.hoverTooltipsDisabled) private var disabled
    /// presenter가 hover 중인 대상을 추적하기 위한 대상별 고정 identity.
    @State private var id = UUID()
    /// presenter가 bubble을 대상 자체에 anchor하기 위한 backing view 추적.
    @State private var anchor = TooltipAnchor()
    /// cursor가 현재 이 대상 안에 있는지 — hover 이벤트 없이 텍스트가 바뀔 때의 판단 기준.
    @State private var isHovering = false

    /// 없거나 빈 문자열이면 `nil` — 두 "absent" case 통합.
    private var resolved: String? {
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled {
            // off-screen render(share card): anchor view/hover 추적 없음 — export PNG의 placeholder artifact 방지.
            content
        } else {
            decorated(content)
        }
    }

    private func decorated(_ content: Content) -> some View {
        content
            // 자손은 한 단계 깊게 — hover가 겹치면 자식 대상이 우선.
            .environment(\.tooltipDepth, depth + 1)
            .background { TooltipAnchorView(anchor: anchor) }
            .accessibilityHint(resolved ?? "")
            // plain `onHover`가 아닌 continuous — presenter가 항상 live hover 상태를 보유.
            .onContinuousHover { phase in
                switch phase {
                case .active:
                    isHovering = true
                    syncPresenter()
                case .ended:
                    // `resolved`와 무관하게 항상 exit — hover 중 텍스트가 nil이 되면 tooltip이 잔존할 수 있음.
                    isHovering = false
                    TooltipPresenter.shared.exit(id: id)
                }
            }
            // cursor가 정지한 채 텍스트가 바뀔 수 있으므로(30초 tick 등) 여기서 reconcile.
            .onChange(of: resolved) { syncPresenter() }
            // `.ended` 없이 행이 해체될 수 있으므로(scroll, 화면 전환) 여기서도 정리.
            .onDisappear {
                isHovering = false
                TooltipPresenter.shared.exit(id: id)
            }
    }

    /// 현재 hover 상태를 presenter에 반영 — hover 중 텍스트 있으면 enter, 없으면 exit; hover 아니면 no-op.
    private func syncPresenter() {
        guard isHovering else { return }
        if let resolved {
            TooltipPresenter.shared.enter(id: id, text: resolved, depth: depth, anchor: anchor)
        } else {
            TooltipPresenter.shared.exit(id: id)
        }
    }
}

/// 재사용되는 단일 tooltip panel을 소유하고 표시할 hover 대상을 결정 — main-actor isolated.
@MainActor
private final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private struct Target {
        let text: String
        let depth: Int
        let anchor: TooltipAnchor
    }

    /// cursor가 현재 들어 있는 대상들 — 둘 이상은 부모/자식 중첩 시뿐, 가장 깊은 쪽이 우선.
    private var active: [UUID: Target] = [:]
    /// 화면에 표시 중인 대상(live 텍스트 변경 감지용 텍스트 포함)과 reveal이 예약된 대상.
    private var shownID: UUID?
    private var shownText: String?
    private var pendingID: UUID?
    private var revealTask: Task<Void, Never>?

    /// 새 tooltip 표시 전의 단일 dwell(400ms) — fast-reshow "quick mode" 없음: 인접 label을 훑을 때
    /// tooltip이 연쇄 flash하는 문제 방지. 조정 시 reshow 재도입보다 delay 상향(≤500ms)이 먼저.
    private let revealDelay: Duration = .milliseconds(400)

    private let anchorGap: CGFloat = 10

    /// 이 폭을 넘으면 여러 줄로 wrap(#696) — popover 폭보다 좁게 유지.
    private let maxTooltipWidth: CGFloat = 280

    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private let panel = NonKeyPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],   // init에서 1회 설정 — 이후 토글은 activation desync 유발
        backing: .buffered,
        defer: false
    )

    private init() {
        // panel을 즉시 구성 — hosting view가 처음부터 window 안에 있어 첫 show에서 `fittingSize`가 올바르게 측정됨.
        panel.isFloatingPanel = true
        // popover(`.popUpMenu`)보다 한 단계 높은 level — `orderFrontRegardless`는 같은 level 안에서만 앞서므로
        // popover 클릭이 tooltip을 뒤로 묻는 문제(#696) 방지.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true                   // click-through — hover를 가로채지 않음
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true                            // window shadow가 bubble의 rounded shape을 따름
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.contentView = host
    }

    func enter(id: UUID, text: String, depth: Int, anchor: TooltipAnchor) {
        active[id] = Target(text: text, depth: depth, anchor: anchor)
        refresh()
    }

    func exit(id: UUID) {
        guard active[id] != nil else { return }
        active[id] = nil
        refresh()
    }

    /// 전체 정리 — popover close 시 호출. SwiftUI tree가 `orderOut`을 넘어 살아남아 `.ended`/`.onDisappear`가
    /// 오지 않으므로 필요.
    func dismissAll() {
        active.removeAll()
        cancelPending()
        hide()
    }

    /// panel을 가장 깊은 active 대상과 reconcile — 저렴하고 idempotent해 per-pixel hover 호출 대부분 early return.
    private func refresh() {
        guard let top = active.max(by: { $0.value.depth < $1.value.depth }) else {
            cancelPending()
            hide()
            return
        }
        if shownID == top.key {                     // 이미 올바른 대상이 표시 중
            if shownText != top.value.text {        // 텍스트만 live 변경 — 재표시
                present(top.value)
                shownText = top.value.text
            }
            return
        }
        // hover된 자손은 화면의 부모를 즉시 대체 — dwell은 부모에서 이미 지불됨. `active[shownID]` 확인으로
        // stale 비교가 아닌 진짜 부모→자식 handoff만 허용.
        if let shownID, let shown = active[shownID], top.value.depth > shown.depth {
            present(top.value)
            self.shownID = top.key
            shownText = top.value.text
            cancelPending()
            return
        }
        // 그 외 전환(sibling/얕은 대상)은 숨기고 새 대상이 dwell을 다시 지불 — sweep 중 tooltip retarget 방지.
        if shownID != nil {
            hide()
        }
        if pendingID == top.key { return }          // 이미 이 대상으로 예약됨
        cancelPending()
        pendingID = top.key
        let target = top.value
        let id = top.key
        let delay = revealDelay
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.present(target)
            self.shownID = id
            self.shownText = target.text
            self.pendingID = nil
            self.revealTask = nil
        }
    }

    private func cancelPending() {
        revealTask?.cancel()
        revealTask = nil
        pendingID = nil
    }

    private func hide() {
        shownID = nil
        shownText = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func present(_ target: Target) {
        let size = measuredSize(for: target)
        panel.setContentSize(size)
        // 대상 view가 이미 사라졌으면 cursor 위치의 빈 rect로 fallback(방어적).
        let cursor = NSEvent.mouseLocation
        let anchorRect = target.anchor.screenRect
            ?? NSRect(x: cursor.x, y: cursor.y, width: 0, height: 0)
        panel.setFrameOrigin(origin(for: size, anchor: anchorRect))
        panel.orderFrontRegardless()                   // 앱 activation/key 없이 표시
    }

    /// 자연 크기로 측정 후 `maxTooltipWidth` 초과 시에만 wrap 재측정(#696). wrap 폭은 같은 줄 수를 유지하는
    /// 최소 폭을 binary search로 탐색 — 줄 길이 균등화, orphan 단어 방지. 최종 bubble이 `host.rootView`에 남음.
    private func measuredSize(for target: Target) -> CGSize {
        func fit(maxTextWidth: CGFloat?) -> CGSize {
            host.rootView = AnyView(TooltipBubble(text: target.text, maxTextWidth: maxTextWidth))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }
        let natural = fit(maxTextWidth: nil)
        guard natural.width > maxTooltipWidth else { return natural }
        let maxTextWidth = maxTooltipWidth - 2 * TooltipBubble.horizontalPadding
        let wrapped = fit(maxTextWidth: maxTextWidth)
        // 폭이 줄수록 높이는 단조 증가 — 최대폭 layout보다 높지 않은 최소 텍스트 폭을 1pt 단위로 binary search.
        var tooNarrow: CGFloat = 0
        var fits = maxTextWidth
        while fits - tooNarrow > 1 {
            let mid = (tooNarrow + fits) / 2
            if fit(maxTextWidth: mid).height > wrapped.height {
                tooNarrow = mid
            } else {
                fits = mid
            }
        }
        return fit(maxTextWidth: fits.rounded(.up))
    }

    /// anchor 위 중앙 배치 후 anchor의 screen에 clamp — 상단이 잘리면 anchor 아래로 flip.
    /// 모든 계산은 Cocoa screen 좌표(bottom-left origin).
    private func origin(for size: CGSize, anchor: NSRect) -> NSPoint {
        var x = anchor.midX - size.width / 2
        var y = anchor.maxY + anchorGap
        // `contains` 조건은 cursor fallback의 zero-size anchor용 — 빈 rect는 어떤 것과도 intersect하지 않음.
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) || $0.frame.contains(anchor.origin) }
            ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // leading edge를 visible frame 안으로 clamp — bubble이 화면보다 넓어도 왼쪽 edge 유지.
            x = max(visible.minX, min(x, visible.maxX - size.width))
            if y + size.height > visible.maxY {
                y = anchor.minY - anchorGap - size.height
            }
            y = max(y, visible.minY)
        }
        return NSPoint(x: x, y: y)
    }

}

/// non-SwiftUI 코드(status-item controller)가 popover close 시 tooltip을 정리하는 seam — `TooltipPresenter`는 private.
@MainActor
enum HoverTooltips {
    static func dismissAll() { TooltipPresenter.shared.dismissAll() }
}

/// key/main이 되지 않는 panel — 표시가 focus를 빼앗아 transient popover를 dismiss하지 않음.
private final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// panel 안에 그리는 bubble — solid fill + hairline border(opaque popover와 일치), `fittingSize`가 panel 크기를 결정.
private struct TooltipBubble: View {
    let text: String
    /// 설정 시 이 폭으로 wrap — `nil`이면 한 줄 유지.
    let maxTextWidth: CGFloat?

    /// 텍스트 좌우 padding — `TooltipPresenter`가 wrap 폭 계산 시 차감.
    static let horizontalPadding: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        label
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 5)
            .background { shape.fill(Color(nsColor: .windowBackgroundColor)) }
            .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    @ViewBuilder
    private var label: some View {
        let content = Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
        if let maxTextWidth {
            // `maxWidth`가 아닌 고정 width — wrapped 높이가 `fittingSize`로 결정적으로 측정됨.
            content.frame(width: maxTextWidth, alignment: .center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}
