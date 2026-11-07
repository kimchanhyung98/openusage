import CoreGraphics

/// popover의 resolved transparency level — 이산 단계 유지로 우선순위 규칙·접근성 clamp·시각 회귀 테스트 단순화
enum PopoverTransparencyStyle: Equatable, Sendable {
    case opaque
    /// 정식 "Increase Transparency" — vibrancy로 desktop 투과, 텍스트 가독 유지
    case increased
    /// secret-code 이스터에그 — `increased`와 같은 translucent 기반 위에 party gradient·glow, 텍스트는 가독 유지
    case party
    /// party + "Drunk Mode" — 의도적으로 겨우 읽히는 흐림·haze·sway 상태
    case drunk

    /// page tray·card의 base 도장 방식
    var surfaceTreatment: PopoverSurfaceTreatment {
        switch self {
        case .opaque: return .opaque
        // translucent 3종 모두 page를 비워 behind-window vibrancy backdrop 노출 — party는 그 backdrop을 tint
        case .increased, .party, .drunk: return .translucent
        }
    }

    /// window 수준 alpha — drunk만 window 전체(텍스트 포함)를 fade, 나머지는 translucent backdrop으로만 투과
    var windowAlpha: CGFloat {
        switch self {
        case .opaque, .increased, .party: return 1
        case .drunk: return 0.62
        }
    }

    /// 표면이 haze가 되면 window shadow가 딱딱한 사각형으로 읽혀 drunk에서 제거
    var wantsShadow: Bool {
        switch self {
        case .opaque, .increased, .party: return true
        case .drunk: return false
        }
    }

    /// custom Liquid Glass control의 adaptive material backing 필요 여부 — translucent 가독 모드에서만 필요
    var needsChromeLegibilityBacking: Bool {
        switch self {
        case .increased, .party: return true
        case .opaque, .drunk: return false
        }
    }

    /// 우선순위 규칙의 단일 지점 — Reduce Transparency·Increase Contrast는 접근성 필요라 모든 것을 opaque로 clamp,
    /// egg도 예외 없이 양보. flag off면 egg > 정식 toggle > opaque 순
    static func resolve(
        increaseTransparency: Bool,
        secretCodeActive: Bool,
        drunkMode: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> PopoverTransparencyStyle {
        // 접근성이 모든 translucent 처리보다 우선, egg 포함
        if reduceTransparency || increaseContrast {
            return .opaque
        }
        if secretCodeActive {
            return drunkMode ? .drunk : .party
        }
        if increaseTransparency {
            return .increased
        }
        return .opaque
    }
}
