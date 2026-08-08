import SwiftUI

extension View {
    /// "too much transparency" easter-egg 처리 — 안정된 modifier 하나로 적용되어 on/off가 snap 대신 ~0.55s crossfade.
    /// `.party`는 읽을 수 있는 파티(콘텐츠는 frosted 카드 위에 선명), `.drunk`는 의도적으로 겨우 읽히는 pink-glass 혼돈,
    /// `.opaque`/`.increased`는 효과 없음.
    func tooMuchTransparency(_ style: PopoverTransparencyStyle) -> some View {
        modifier(TooMuchTransparencyModifier(style: style))
    }
}

/// 공유 party 팔레트 — hot pink, violet, teal, amber.
private let partyColors: [Color] = [
    Color(red: 1.00, green: 0.32, blue: 0.74),
    Color(red: 0.62, green: 0.40, blue: 1.00),
    Color(red: 0.30, green: 0.85, blue: 0.95),
    Color(red: 1.00, green: 0.72, blue: 0.30),
    Color(red: 1.00, green: 0.32, blue: 0.74),
]

/// `style`에 따라 레이어가 오가는 안정된 단일 modifier.
/// `.animation(value:)` + 레이어별 `.transition(.opacity)`가 egg 토글의 fade를 만들고, AppKit window alpha도 같은 ease로 crossfade.
private struct TooMuchTransparencyModifier: ViewModifier {
    let style: PopoverTransparencyStyle

    private var isParty: Bool { style == .party }
    private var isDrunk: Bool { style == .drunk }

    func body(content: Content) -> some View {
        content
            .modifier(DrunkDistortion(active: isDrunk))
            .background {
                if isParty { PartyBackdrop().transition(.opacity) }
            }
            .overlay {
                if isParty { PartyRim().transition(.opacity).allowsHitTesting(false) }
            }
            .overlay {
                if isDrunk { DrunkOverlays().transition(.opacity).allowsHitTesting(false) }
            }
            .environment(\.popoverPartyMode, isParty)
            .animation(.easeInOut(duration: 0.55), value: style)
    }
}

// MARK: - Party (loud but readable)

/// popover를 틴트하는 서서히 휘도는 vivid gradient — frosted 콘텐츠 뒤에 위치.
/// 의도적 반투명 — SwiftUI `blendMode`는 AppKit vibrancy view와 합성 불가라 desktop은 alpha로만 비침.
private struct PartyBackdrop: View {
    var body: some View {
        // churning clock은 popover가 보일 때만 mount(`VisibilityGatedTimeline` 참고).
        VisibilityGatedTimeline { t in gradient(at: t) }
    }

    private func gradient(at t: TimeInterval) -> some View {
        ZStack {
            AngularGradient(colors: partyColors, center: .center, angle: .degrees(t * 28))
                .opacity(0.5)   // translucent 틴트 — 블러된 desktop이 색과 섞여 비침
            RadialGradient(
                colors: [Color.white.opacity(0.15), .clear],
                center: UnitPoint(x: 0.5 + cos(t * 0.5) * 0.3, y: 0.5 + sin(t * 0.6) * 0.3),
                startRadius: 0,
                endRadius: 240
            )
            .blendMode(.plusLighter)
        }
    }
}

/// popover 가장자리를 도는 발광 rim — 텍스트 위로는 절대 올라오지 않음.
private struct PartyRim: View {
    var body: some View {
        VisibilityGatedTimeline { t in rim(at: t) }
    }

    private func rim(at t: TimeInterval) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(
                AngularGradient(colors: partyColors, center: .center, angle: .degrees(-t * 36)),
                lineWidth: 2.5
            )
            .shadow(color: Color(red: 1, green: 0.4, blue: 0.85).opacity(0.7), radius: 7)
    }
}

// MARK: - Drunk (the woozy, barely-readable escalation)

/// 콘텐츠의 blur·hue-wobble·비틀거림 — 비활성 시 identity(`TimelineView` 없음, 비용 0).
/// active + hidden은 static frame으로 동결 — inactive 분기로 합치면 popover가 닫히는 순간 blur가 눈에 띄게 사라짐.
private struct DrunkDistortion: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        // 세 상태 구분 유지: active+표시 → live, active+숨김 → static frame 동결, inactive → 원본(비용 0).
        if active {
            VisibilityGatedTimeline { t in distort(content, at: t) }
        } else {
            content
        }
    }

    private func distort(_ content: Content, at t: TimeInterval) -> some View {
        content
            .saturation(1.55)
            .blur(radius: 3.6)
            .hueRotation(.degrees(sin(t * 1.1) * 16))
            .scaleEffect(1.05 * (1 + sin(t * 1.2) * 0.018))   // over-scale로 sway 틈 숨김
            .rotationEffect(.degrees(sin(t * 1.5) * 1.1))     // 방이 빙빙 도는 중
    }
}

/// 콘텐츠 위에 겹치는 pink-glass haze — clear-glass 렌즈(의도적 Liquid Glass 남용) + 서서히 휘도는 pink wash.
private struct DrunkOverlays: View {
    var body: some View {
        VisibilityGatedTimeline { t in haze(at: t) }
    }

    private func haze(at t: TimeInterval) -> some View {
        ZStack {
            glassLens()
            AngularGradient(colors: partyColors, center: .center, angle: .degrees(t * 26))
                .opacity(0.5)
        }
    }

    @ViewBuilder
    private func glassLens() -> some View {
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.clear, in: Rectangle())
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}
