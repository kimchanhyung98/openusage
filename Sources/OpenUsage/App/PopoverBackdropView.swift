import AppKit

/// popover panel의 backdrop: 한 번 구성해 가시성으로 전환하는 두 full-frame layer (`.opaque` tray / `.translucent` vibrancy).
/// 두 child는 상시 mount·full frame 고정 필수 — toggle 시 rebuild는 mode observer와 race, 부분 frame은 morph 중 투명 strip 노출.
/// mode 전환은 alpha crossfade — snap 대신 ease.
final class PopoverBackdropView: NSView {
    enum Mode { case opaque, translucent }

    private let opaqueBox = NSBox()
    private let vibrancy = NSVisualEffectView()
    private var currentMode: Mode = .opaque

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        opaqueBox.boxType = .custom
        opaqueBox.titlePosition = .noTitle
        opaqueBox.borderWidth = 0
        opaqueBox.cornerRadius = cornerRadius
        opaqueBox.contentViewMargins = .zero
        opaqueBox.fillColor = Theme.trayNSColor
        opaqueBox.wantsLayer = true                 // alphaValue 애니메이션용 layer-backed
        opaqueBox.translatesAutoresizingMaskIntoConstraints = false

        vibrancy.material = .popover
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        // behind-window blur는 부모 layer의 corner mask 미보장 — 자체 rounded mask 필요.
        vibrancy.maskImage = Self.roundedMaskImage(cornerRadius: cornerRadius)
        vibrancy.wantsLayer = true
        vibrancy.alphaValue = 0                      // 기본은 opaque tray — 숨김으로 시작
        vibrancy.translatesAutoresizingMaskIntoConstraints = false

        // opaque box를 vibrancy 위에 배치 — 기본 look이 완전 커버 (방어적 순서).
        addSubview(vibrancy)
        addSubview(opaqueBox, positioned: .above, relativeTo: vibrancy)
        NSLayoutConstraint.activate([
            vibrancy.leadingAnchor.constraint(equalTo: leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: trailingAnchor),
            vibrancy.topAnchor.constraint(equalTo: topAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: bottomAnchor),
            opaqueBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            opaqueBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            opaqueBox.topAnchor.constraint(equalTo: topAnchor),
            opaqueBox.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 지정 backdrop layer로 crossfade. 초기 상태는 `animated: false` — 런치 fade-in 방지.
    /// animated 시 caller가 window-alpha 변경과 동일 `NSAnimationContext` group으로 wrapping.
    func setMode(_ mode: Mode, animated: Bool) {
        guard mode != currentMode else { return }
        currentMode = mode
        let opaqueAlpha: CGFloat = mode == .opaque ? 1 : 0
        let vibrancyAlpha: CGFloat = mode == .opaque ? 0 : 1
        if animated {
            opaqueBox.animator().alphaValue = opaqueAlpha
            vibrancy.animator().alphaValue = vibrancyAlpha
        } else {
            opaqueBox.alphaValue = opaqueAlpha
            vibrancy.alphaValue = vibrancyAlpha
        }
    }

    /// stretchable rounded-rectangle mask — cap inset이 corner radius와 동일해 모든 크기에서 corner 유지.
    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let side = cornerRadius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                       bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
}
