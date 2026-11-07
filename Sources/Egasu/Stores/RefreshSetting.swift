import Foundation

/// 사용량 조회·캐시·표시의 대상별 주기. 자동 전환 관측은 일반 주기인 `interval` 사용.
enum RefreshSetting {
    static let defaultMinutes = 5
    static let interval = TimeInterval(defaultMinutes * 60)
    static let slowInterval: TimeInterval = 15 * 60

    enum Cadence: CaseIterable, Sendable {
        case regular, claude

        var interval: TimeInterval {
            self == .claude ? RefreshSetting.slowInterval : RefreshSetting.interval
        }
    }

    static func cadence(for providerID: String) -> Cadence {
        ProviderAccountID.family(of: providerID) == "claude" ? .claude : .regular
    }

    static func interval(for providerID: String) -> TimeInterval {
        cadence(for: providerID).interval
    }
}
