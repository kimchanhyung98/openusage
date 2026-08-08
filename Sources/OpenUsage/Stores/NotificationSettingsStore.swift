import Foundation
import Observation

/// quota pace 알림 사용자 설정 — milestone별 trigger 3종, master switch 없음 (셋 다 꺼야 무음)
/// 전부 기본 OFF — 첫 trigger on 시점에 알림 권한 요청, 신규 설치는 opt-in 전까지 조용함
@MainActor
@Observable
final class NotificationSettingsStore {
    private let defaults: UserDefaults

    private static let underTenKey = "openusage.notifications.underTenPercent"
    private static let healthyToCloseKey = "openusage.notifications.healthyToClose"
    private static let closeToRunningOutKey = "openusage.notifications.closeToRunningOut"

    /// 기간 내 잔여 10% 미만 최초 진입 시 알림
    var underTenPercent: Bool {
        didSet { defaults.set(underTenPercent, forKey: Self.underTenKey) }
    }

    /// pace가 healthy(파랑)에서 close-to-limit(노랑)로 악화 시 알림
    var healthyToClose: Bool {
        didSet { defaults.set(healthyToClose, forKey: Self.healthyToCloseKey) }
    }

    /// pace가 close-to-limit(노랑)에서 running-out(빨강)로 악화 시 알림
    var closeToRunningOut: Bool {
        didSet { defaults.set(closeToRunningOut, forKey: Self.closeToRunningOutKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.underTenPercent = defaults.bool(forKey: Self.underTenKey, default: false)
        self.healthyToClose = defaults.bool(forKey: Self.healthyToCloseKey, default: false)
        self.closeToRunningOut = defaults.bool(forKey: Self.closeToRunningOutKey, default: false)
    }

    /// 순수 logic이 소비하는 형태의 milestone toggle 묶음
    var toggles: PaceNotificationToggles {
        PaceNotificationToggles(
            underTenPercent: underTenPercent,
            healthyToClose: healthyToClose,
            closeToRunningOut: closeToRunningOut
        )
    }

    /// trigger 하나 이상 on 여부 — 권한 요청 시점과 Settings 권한 notice 표시 판단에 사용
    var anyEnabled: Bool { underTenPercent || healthyToClose || closeToRunningOut }
}
