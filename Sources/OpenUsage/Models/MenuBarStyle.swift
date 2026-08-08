import Foundation

/// menu-bar item의 pinned metric 렌더 방식 — `text` strip 또는 compact `bars` glyph.
/// Settings에서 선택, `LayoutStore`가 persist — 기본값 `.bars`.
enum MenuBarStyle: String, Hashable, Sendable, CaseIterable {
    case text
    case bars

    var label: String {
        switch self {
        case .text: return "Text"
        case .bars: return "Bars"
        }
    }
}
