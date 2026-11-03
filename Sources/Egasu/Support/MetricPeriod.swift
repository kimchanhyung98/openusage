import Foundation

/// provider들이 공유하는 표준 usage-window 길이(ms) — 같은 window가 mapper마다 magic number로 재정의되지 않도록 함.
enum MetricPeriod {
    static let sessionMs = 5 * 60 * 60 * 1000
    static let dayMs = 24 * 60 * 60 * 1000
    static let weekMs = 7 * dayMs
    static let monthMs = 30 * dayMs
}
