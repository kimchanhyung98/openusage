import SwiftUI

/// popover가 쓰는 macOS 26(Tahoe) Liquid Glass API의 availability-gated wrapper — macOS 15에서도 빌드·동작 유지.
/// 순수 cosmetic fallback: 기능은 모든 OS에서 보존되고, glass는 footer chrome 전용으로 콘텐츠 카드에는 미적용.
/// `#available(macOS 26, *)` 분기를 이 파일에 모아 view 코드의 inline availability 분기 제거.
extension View {
    /// macOS 26에서는 Liquid Glass, macOS 15에서는 대응하는 bordered 버튼 스타일.
    /// `.glass`/`.bordered` 계열은 서로 다른 `PrimitiveButtonStyle` 타입이라 ternary 대신 `@ViewBuilder` 분기 필요.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }

    /// 컨트롤 전체 뒤에 그려지는 단일 interactive Liquid Glass 표면.
    /// 컨테이너에 적용하고 컨트롤은 `.buttonStyle(.plain)` 유지 필요 — 시스템 `.glass`는 `Menu`에서 flat하게 렌더링되고,
    /// segment별 glass는 capsule을 쪼갬. `reinforced`는 밝은 desktop에서도 경계가 유지되도록 frosted material과 hairline 추가.
    @ViewBuilder
    func interactiveGlass(in shape: some InsettableShape, reinforced: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if reinforced {
                background(.regularMaterial, in: shape)
                    .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                glassEffect(.regular.interactive(), in: shape)
            }
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        }
    }

    /// 전체 chrome bar(footer/top bar)용 Liquid Glass 표면 — macOS 26+는 `glassEffect`, macOS 15는 frosted material.
    @ViewBuilder
    func barGlass() -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: Rectangle())
        } else {
            background(.bar)
        }
    }

    /// 스크롤 콘텐츠 아래에 bottom bar 고정 — macOS 26은 scroll-edge blur를 주는 `safeAreaBar`, macOS 15는 blur 없는 `safeAreaInset`.
    @ViewBuilder
    func pinnedFooter<Footer: View>(spacing: CGFloat, @ViewBuilder content: () -> Footer) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: spacing, content: content)
        }
    }

    /// 스크롤 콘텐츠 위에 bar 고정 — macOS 26은 scroll-edge blur를 주는 `safeAreaBar`, macOS 15는 blur 없는 `safeAreaInset`.
    @ViewBuilder
    func pinnedTopBar<Bar: View>(spacing: CGFloat, @ViewBuilder content: () -> Bar) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .top, spacing: spacing, content: content)
        } else {
            safeAreaInset(edge: .top, spacing: spacing, content: content)
        }
    }

    /// macOS 26의 soft top scroll-edge effect 적용 — macOS 15는 대응 API가 없어 no-op.
    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }

    /// macOS 26의 soft bottom scroll-edge effect 적용 — 고정 footer 아래로 지나는 콘텐츠의 blur fade. macOS 15는 no-op.
    @ViewBuilder
    func softBottomScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .bottom)
        } else {
            self
        }
    }
}
