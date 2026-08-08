import Foundation

/// 모든 bounded row의 reset countdown 표시 방식 전역 설정 — 상대 시간("Resets in 4d 17h") 또는 절대 시각.
/// reset label 클릭으로 toggle. label 문구는 relative/absolute 용어 대신 각 mode의 표시 형태 기술.
enum ResetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case relative
    case absolute

    var label: String {
        switch self {
        case .relative: return "Countdown"
        case .absolute: return "Exact Time"
        }
    }

    mutating func toggle() {
        self = self == .relative ? .absolute : .relative
    }
}
