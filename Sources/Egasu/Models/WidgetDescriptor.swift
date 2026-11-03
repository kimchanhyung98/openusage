import Foundation

/// provider metric의 identity와 presentation template.
/// live provider line이 값 공급, `sample`은 title·icon·kind 등 고정 표시 metadata와 descriptor opt-in 전달.
struct WidgetDescriptor: Identifiable, Hashable {
    let id: String                 // 예: "claude.session"
    let providerID: String
    let metricLabel: String
    let sample: WidgetData
    /// menu-bar strip pin 가능 여부 — tray가 값으로 못 그리는 tile(Usage Trend chart)은 false, "0"으로 읽힐 pin 차단.
    var pinnable: Bool = true
    /// `SpendTileMapper` 기반 spend-history tile 전용 true (`WidgetDescriptor.spendTiles`).
    /// Total Spend 카드의 ring 공급 판정 key — title 매칭은 유사 row 오인 위험.
    var isSpendTile: Bool = false
    /// `/v1/limits`가 export하는 안정적 scalar resource — UI 전용/history widget은 빈 배열.
    var limitResources: [LimitResourceDescriptor] = []
    /// provider 정규화 일별 history의 명시적 집계 semantics — shared spend tile 보유 provider마다 descriptor 정확히 하나가 보유.
    var historyResource: UsageHistoryDescriptor? = nil
    /// 사용자 soft-limit 안내선 대상 window — provider 선언이 명시적으로 opt-in.
    var softLimitWindow: SoftLimitWindow? = nil

    var title: String { sample.title }

    static func == (lhs: WidgetDescriptor, rhs: WidgetDescriptor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
