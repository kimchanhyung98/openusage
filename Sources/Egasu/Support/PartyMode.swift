import SwiftUI

/// 가독형 "party" easter-egg 모드 여부 — leaf view(meter bar, provider mark)가 가독성을 유지한 채 참여.
/// 기본값 `false` — windowless ShareCard export와 일반 surface는 opt-in하지 않음.
private struct PopoverPartyModeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var popoverPartyMode: Bool {
        get { self[PopoverPartyModeKey.self] }
        set { self[PopoverPartyModeKey.self] = newValue }
    }
}

/// 호스팅 popover의 on-screen 여부 — easter-egg loop가 보일 때만 `TimelineView(.animation)` clock을 mount해
/// 닫힌 popover가 display link·CPU를 쓰지 않도록 함. 기본값 `false`라 windowless ShareCard export는 loop 미장착.
/// 구조적 mount gate 필수 — `TimelineView(.animation(paused:))` overload는 in-place 활성화가 얼어 회귀됨; 되돌리기 금지.
private struct PopoverIsVisibleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var popoverIsVisible: Bool {
        get { self[PopoverIsVisibleKey.self] }
        set { self[PopoverIsVisibleKey.self] = newValue }
    }
}

/// popover가 보일 때는 live `TimelineView(.animation)`, 숨겨지면 단일 static frame으로 `content(t)` 렌더 —
/// 모든 easter-egg loop가 공유하는 구조적 mount gate(`\.popoverIsVisible` 참고).
/// 두 분기 모두 `.transition(.identity)`라 egg 토글이 hard cut 없이 crossfade됨. `t`는 `timeIntervalSinceReferenceDate`.
struct VisibilityGatedTimeline<Content: View>: View {
    @Environment(\.popoverIsVisible) private var shown
    private let content: (TimeInterval) -> Content

    init(@ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.content = content
    }

    var body: some View {
        if shown {
            TimelineView(.animation) { timeline in
                content(timeline.date.timeIntervalSinceReferenceDate)
            }
            .transition(.identity)
        } else {
            content(Date().timeIntervalSinceReferenceDate)
                .transition(.identity)
        }
    }
}

enum PartyMode {
    /// party 모드 meter bar의 vivid gradient fill — bar는 여전히 너비로 fraction을 보여 가독성 유지.
    static let meterFill = AnyShapeStyle(
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.35, blue: 0.78),
                Color(red: 0.60, green: 0.42, blue: 1.00),
                Color(red: 0.30, green: 0.85, blue: 1.00),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    )
}

extension View {
    /// party 모드 중 provider mark의 완만한 pulse + 색 shimmer; off일 때는 identity(`TimelineView` 미장착).
    @ViewBuilder
    func partyPulse(_ active: Bool) -> some View {
        if active {
            modifier(PartyPulseModifier())
        } else {
            self
        }
    }
}

private struct PartyPulseModifier: ViewModifier {
    func body(content: Content) -> some View {
        // clock은 popover가 보일 때만 mount(`VisibilityGatedTimeline` 참고) — 닫힌 동안 비용 없음.
        VisibilityGatedTimeline { t in pulse(content, at: t) }
    }

    private func pulse(_ content: Content, at t: TimeInterval) -> some View {
        content
            .scaleEffect(1 + sin(t * 3.2) * 0.12)
            .hueRotation(.degrees(sin(t * 2.0) * 28))
    }
}
