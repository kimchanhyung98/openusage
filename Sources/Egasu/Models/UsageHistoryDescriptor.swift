import Foundation

/// provider 일별 spend history의 Mac 간 합산 가능 여부.
/// shared spend tile 보유 provider의 명시 선언 필수 — account-wide source의 이중 계산 방지.
struct UsageHistoryDescriptor: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable {
        case machineLocal
        case accountWide
    }

    let scope: Scope
    let estimatedCost: Bool
    let sourceNote: String
}

extension WidgetDescriptor {
    /// provider의 정규화 일별 history를 다른 machine-facing export와 나란히 분류.
    func exportingHistory(
        scope: UsageHistoryDescriptor.Scope,
        estimatedCost: Bool,
        sourceNote: String
    ) -> WidgetDescriptor {
        var copy = self
        copy.historyResource = UsageHistoryDescriptor(
            scope: scope,
            estimatedCost: estimatedCost,
            sourceNote: sourceNote
        )
        return copy
    }
}
