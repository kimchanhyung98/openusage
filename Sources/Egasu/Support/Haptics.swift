import AppKit

/// Force Touch Taptic Engine 기반 trackpad haptics — 미지원 하드웨어에서는 조용한 no-op.
/// drag 전용 — mouse-click 액션에서 발화 금지. Force Touch 클릭 자체가 Taptic pulse라 앱 pulse가 겹치면 이중 진동으로 읽힘.
@MainActor
enum Haptics {
    /// "snap" tap — drag이 실제로 새 순서를 commit할 때만 발화, 단순 drag 이동에서는 금지.
    /// commit당 `.levelChange` pulse 정확히 1회; 최소 간격 floor는 빠른 drag의 연속 pulse가 buzz로 뭉개지는 것 방지.
    private static let minimumSnapInterval: TimeInterval = 0.12
    private static var lastSnapAt: TimeInterval = 0

    static func snap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSnapAt >= minimumSnapInterval else { return }
        lastSnapAt = now

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
