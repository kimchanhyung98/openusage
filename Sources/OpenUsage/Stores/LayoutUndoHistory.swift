import Foundation

/// 사용자 액션이 바꿀 수 있는 layout 상태 전체의 불변 capture — undo stack의 저장 단위
/// 액션별 역연산 대신 전체 snapshot 복원으로 모든 액션을 한 경로에서 undo, 연동 상태의 drift 방지
/// Equatable로 no-op 액션의 snapshot push 생략 지원
struct LayoutSnapshot: Equatable {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
    let expandedMetricIDs: Set<String>
    let defaultExpandedOnEnableIDs: Set<String>
}

/// `LayoutStore` 앱 전역 ⌘Z를 받치는 bounded undo stack
/// session 한정 (store가 persist하지 않음), store의 사용자 대상 mutation 전부를 snapshot 복원으로 커버
struct LayoutUndoHistory {
    /// ⌘Z 최대 깊이 — 실제 편집 session을 덮으면서 무한 증식하지 않는 수준
    static let maxDepth = 40

    private(set) var snapshots: [LayoutSnapshot] = []

    var canUndo: Bool { !snapshots.isEmpty }

    /// 변경 전 snapshot을 최신 undo step으로 push — 상한 초과 시 가장 오래된 step 제거
    mutating func record(_ snapshot: LayoutSnapshot) {
        snapshots.append(snapshot)
        if snapshots.count > Self.maxDepth {
            snapshots.removeFirst(snapshots.count - Self.maxDepth)
        }
    }

    /// 복원할 최신 snapshot pop, undo 대상 없으면 `nil`
    mutating func popLast() -> LayoutSnapshot? {
        snapshots.popLast()
    }

    /// 기록 전체 삭제 — layout reset 시 pre-reset 배치로의 undo 부활 방지
    mutating func clear() {
        snapshots.removeAll()
    }
}
