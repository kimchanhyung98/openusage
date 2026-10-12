import Foundation

/// 사용량 조회·캐시·표시가 공유하는 고정 주기. 자동 전환의 실시간 관측 유효 기간은 별도 유지.
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
