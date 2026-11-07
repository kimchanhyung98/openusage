import Foundation

/// dashboard 상단 cross-provider Total Spend card 표시 여부 (기본 on)
/// 숨김은 card에만 적용 — 집계 대상인 provider별 spend row 배치는 불변
enum TotalSpendSetting {
    static let key = "showTotalSpend"
}
