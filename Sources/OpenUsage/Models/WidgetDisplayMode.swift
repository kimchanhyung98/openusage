import Foundation

enum WidgetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case used
    case remaining

    var label: String {
        switch self {
        case .used: return L10n.settings("Used")
        case .remaining: return L10n.settings("Left")
        }
    }

    mutating func toggle() {
        self = self == .used ? .remaining : .used
    }
}
