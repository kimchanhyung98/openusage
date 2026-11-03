import Foundation
import Observation

/// 1회성 onboarding 상태 — 현재는 첫 실행 Customize hint card 노출 여부 1bit
/// `FirstRunSeeder`가 신규 설치 시딩 시 pending 표시, card 닫기·Customize 방문 시 해제 (기존 설치는 미노출)
@MainActor
@Observable
final class OnboardingStore {
    private static let customizeHintPendingKey = "openusage.onboarding.customizeHintPending"

    private(set) var isCustomizeHintPending: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isCustomizeHintPending = defaults.bool(forKey: Self.customizeHintPendingKey)
    }

    func markCustomizeHintPending() {
        guard !isCustomizeHintPending else { return }
        isCustomizeHintPending = true
        defaults.set(true, forKey: Self.customizeHintPendingKey)
    }

    func dismissCustomizeHint() {
        guard isCustomizeHintPending else { return }
        isCustomizeHintPending = false
        defaults.set(false, forKey: Self.customizeHintPendingKey)
    }
}
