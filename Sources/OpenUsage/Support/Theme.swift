import SwiftUI
import AppKit

/// 중앙 팔레트 + surface 스타일 — surface는 light/dark 적응형 유지.
/// Liquid Glass는 footer/top-bar chrome 전용, 데이터 카드에는 금지 — 콘텐츠 레이어는 표준 material로 받치는 Apple 가이드 준수.
/// 데이터 영역은 macOS System Settings의 grouped look(`.fill.quaternary`)을 따르고 수동 튜닝 값 없음.
enum Theme {
    static let iconGray = AnyShapeStyle(.secondary)

    /// severity band별 meter fill — 수동 hex 없이 macOS 시스템 팔레트 사용으로 light/dark·접근성 설정 자동 추적.
    static func meterFill(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        AnyShapeStyle(meterColor(severity))
    }

    private static func meterColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .neutral: return Color(nsColor: .systemGray)
        case .normal: return Color(nsColor: .systemBlue)
        case .warning: return Color(nsColor: .systemYellow)
        case .critical: return Color(nsColor: .systemRed)
        }
    }

    static let notice = AnyShapeStyle(Color(nsColor: .systemOrange))

    static let positive = AnyShapeStyle(Color(nsColor: .systemGreen))

    // MARK: - Surfaces

    /// grouped card 뒤 popover의 불투명 backdrop("tray") — 문서 view가 쓰는 밝은 page surface인 `textBackgroundColor`.
    /// `NSColor`로 노출해 AppKit backdrop(`StatusItemController`)과 SwiftUI surface가 한 색을 공유.
    static let trayNSColor: NSColor = .textBackgroundColor
    static var traySurface: Color { Color(nsColor: trayNSColor) }

    /// grouped card를 `traySurface` 위로 띄우는 semantic fill — 시스템 자체의 `.fill.quaternary`.
    /// 수동 튜닝 값 없음 — light/dark와 Increase Contrast 자동 추적.
    static let cardFill = AnyShapeStyle(.fill.quaternary)

    static let cardCornerRadius: CGFloat = 12

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    /// provider/settings 카드의 grouped-card surface — System Settings grouped-box look, borderless.
    /// 불투명 page base를 먼저 그려 lifted drag preview가 떠 있는 동안에도 solid 유지.
    func cardSurface() -> some View {
        modifier(CardSurfaceModifier())
    }

    /// 단일 행 lifted preview surface — 카드 surface + 아래 행들과 구분하는 얇은 separator hairline.
    /// 여러 행 provider preview는 hairline 없이 그림자만으로 분리감 표현.
    func liftedRowSurface() -> some View {
        cardSurface()
            .overlay { Theme.cardShape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    /// settings·Customize 행 토글이 공유하는 trailing 스위치 스타일 — inline 라벨 없음, native switch, small 크기.
    func settingsSwitchStyle() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// `cardSurface`의 구현 — 불투명 page base(`traySurface`) 위에 `.fill.quaternary` 합성, borderless grouped box.
/// translucent 처리에서는 page base를 제거해 behind-window vibrancy가 비치되, grouped fill은 유지해 카드 구분 보존.
private struct CardSurfaceModifier: ViewModifier {
    @Environment(\.popoverSurfaceTreatment) private var treatment

    func body(content: Content) -> some View {
        content.background {
            switch treatment {
            case .opaque:
                Theme.cardShape
                    .fill(Theme.traySurface)
                    .overlay { Theme.cardShape.fill(Theme.cardFill) }
            case .translucent:
                // translucent 모드: 카드가 frosted `.regularMaterial`을 직접 실어 텍스트 가독성 유지 — HIG의 표준 material, `glassEffect` 아님.
                Theme.cardShape
                    .fill(.regularMaterial)
                    .overlay { Theme.cardShape.fill(Theme.cardFill) }
            }
        }
    }
}
