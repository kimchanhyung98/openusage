import Foundation

/// 사용자 알림 대상 quota milestone 3종 — 각각 Settings의 per-trigger 토글 하나에 대응, reset window 내 독립 dedup.
enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// 기간 내 quota 잔여 비율의 최초 10% 미만 하락.
    case underTenPercent
    /// pace 판정의 healthy(파랑) → close-to-limit(노랑) 악화.
    case healthyToClose
    /// pace 판정의 close-to-limit(노랑) → running-out(빨강) 악화.
    case closeToRunningOut
}

extension PaceMilestone {
    /// Settings 행과 알림 제목이 공유하는 사용자 표시 라벨(의도적으로 일치).
    var settingLabel: String {
        switch self {
        case .underTenPercent: return "Almost Out"
        case .healthyToClose: return "Cutting It Close"
        case .closeToRunningOut: return "Will Run Out"
        }
    }

    /// 알림 제목 — 탭한 알림이 Settings의 한 행으로 되짚어지도록 setting 라벨과 동일.
    var notificationTitle: String { settingLabel }

    /// 알림 본문 — 평이한 판정 문구. subtitle이 provider + metric을 실으므로 본문은 어떤 metric에도 맞는 일반형 유지.
    var body: String {
        switch self {
        case .underTenPercent: return "Under 10% usage remaining for this window."
        case .healthyToClose: return "Projected to finish close to your limit."
        case .closeToRunningOut: return "Projected to finish before the limit resets."
        }
    }

    /// 발화 조건을 설명하는 Settings 한 줄 tooltip(행 옆 (i)).
    var tooltip: String {
        switch self {
        case .underTenPercent: return "Alert when a limit drops below 10% remaining."
        case .healthyToClose: return "Alert when a limit is projected to finish with little left."
        case .closeToRunningOut: return "Alert when a limit is projected to finish before it resets."
        }
    }
}

/// `MeterState`에서 파생되는 pace 심각도 bucket.
/// 신뢰할 pace가 없는 상태(`noData`, absolute-band `level`, 새 session window)는 `untracked`;
/// `.level`은 잔여 기반 Almost Out milestone은 여전히 발화 가능.
enum PaceBucket: Hashable, Sendable {
    /// 행동할 pace 없음(데이터 없음, 단순 level band, 미시작 session window).
    case untracked
    /// 파랑: 여유 ≥10%로 종료 예상.
    case healthy
    /// 노랑: 마지막 10% 이내 착지 예상.
    case close
    /// 빨강: reset 전 소진 예상 또는 이미 소진.
    case runningOut
}

/// metric(provider + descriptor) 하나의 dedup 상태 — refresh pass를 넘어 유지되어 milestone이 reset window당 1회만 발화.
struct NotificationState: Equatable, Sendable {
    /// fired flag가 속한 window의 reset 시각 — 새 window로 전진하면 fired set이 비워져 같은 milestone 재발화 가능.
    var resetsAt: Date?
    /// 현재 window에서 이미 알림된 milestone.
    var firedMilestones: Set<PaceMilestone> = []
    /// 직전 평가에서 관측된 bucket — 악화 전이 감지용.
    var previousBucket: PaceBucket = .untracked
    /// 직전 평가에서 잔여 10% 미만이었는지 — 10% 미만 진입을 edge로 만들고 10% 초과 회복 시 re-arm.
    var wasUnderTenPercent: Bool = false
    /// 최초의 실제(non-untracked) 관측이 baseline으로 기록되었는지 — 그 전에는 launch 시 이미 나쁜 metric도 발화 없이 기록만 함.
    var primed: Bool = false
}

/// 독립적인 milestone별 토글 3개의 현재 상태.
struct PaceNotificationToggles: Sendable {
    var underTenPercent: Bool
    var healthyToClose: Bool
    var closeToRunningOut: Bool

    func isOn(_ milestone: PaceMilestone) -> Bool {
        switch milestone {
        case .underTenPercent: return underTenPercent
        case .healthyToClose: return healthyToClose
        case .closeToRunningOut: return closeToRunningOut
        }
    }
}

/// 순수 milestone 로직(SwiftUI·UserNotifications 없음) — 발화 규칙의 단위 테스트 유지.
/// `WidgetDataStore.evaluateNotifications`가 metric별 현재 상태를 넘기고 반환된 milestone마다 알림 게시.
enum PaceNotificationLogic {
    /// 평가 1회의 결과 — 지금 발화할 milestone과 다음을 위해 유지할 상태.
    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    /// meter 상태의 pace bucket 매핑. 신뢰할 pace가 없는 상태는 `untracked`; `.level`은 잔여 기반 Almost Out은 발화 가능.
    static func bucket(for state: WidgetData.MeterState) -> PaceBucket {
        switch state {
        case .noData, .level: return .untracked
        case .healthy: return .healthy
        case .closeToLimit: return .close
        case .runningOut, .spent: return .runningOut
        }
    }

    /// 이 pass에서 발화할 milestone과 유지할 상태 결정.
    /// dedup 규칙: 새 reset window(jitter 허용치 초과 전진)는 fired set 초기화; pace milestone은 악화 edge + 토글 on + window 내 미발화일 때만 발화.
    /// `underTenPercent`는 최초 10% 미만 진입에 발화하고 회복 시 re-arm; `untracked`는 pace milestone 억제; 개선은 fired flag를 비워 재발화 허용.
    static func transitions(
        state: WidgetData.MeterState,
        /// 한도의 잔여 비율 0...1 — 표시 모드와 무관하게 "잔여" 의미 필수(호출자는 `WidgetData.remainingFraction` 전달).
        fraction: Double,
        resetsAt: Date?,
        previous: NotificationState,
        toggles: PaceNotificationToggles
    ) -> Transition {
        var next = previous

        // 새 window: dedup 초기화. nil이거나 같으면 window 유지, jitter 허용치보다 늦어지면 새로 시작.
        if resetWindowAdvanced(resetsAt: resetsAt, previousReset: previous.resetsAt) {
            next.firedMilestones = []
            next.wasUnderTenPercent = false
            next.previousBucket = .untracked
        }
        next.resetsAt = resetsAt ?? previous.resetsAt

        let currentBucket = bucket(for: state)

        // 실 데이터 없는 tile은 기록 신호를 건드리지 않고 skip — 일시적 no-data가 개선/악화로 읽히면 안 됨(`.level`은 예외로 아래에서 처리).
        if state == .noData {
            return Transition(fire: [], newState: next)
        }

        // launch 후 첫 실제 관측은 발화 없이 baseline만 기록 — 시작부터 나쁜 quota의 launch 직후 알림 방지; window 전진은 re-prime하지 않음.
        if !next.primed {
            next.primed = true
            next.previousBucket = currentBucket
            next.wasUnderTenPercent = fraction < 0.10
            next.firedMilestones = []
            return Transition(fire: [], newState: next)
        }

        var fire: [PaceMilestone] = []

        // pace 판정 edge — live-pace 상태 전용. 파랑→빨강 직행은 Will Run Out만 발화(둘 동시 발화 없음).
        if currentBucket != .untracked {
            let previousSeverity = severity(next.previousBucket)
            let currentSeverity = severity(currentBucket)
            var paceFired = false
            if currentBucket == .close, previousSeverity < severity(.close) {
                if maybeFire(.healthyToClose, into: &fire, state: &next, toggles: toggles) { paceFired = true }
            }
            if currentSeverity >= severity(.runningOut), previousSeverity < severity(.runningOut) {
                if maybeFire(.closeToRunningOut, into: &fire, state: &next, toggles: toggles) { paceFired = true }
            }
            // pace 개선은 무관해진 fired flag를 비워 이후 악화가 재발화되도록 함.
            if currentSeverity < previousSeverity {
                if currentSeverity <= severity(.healthy) { next.firedMilestones.remove(.healthyToClose) }
                if currentSeverity <= severity(.close) { next.firedMilestones.remove(.closeToRunningOut) }
            }
            // 악화가 실제로 알림됐거나 악화가 없을 때만 기록 bucket 전진 — 잡히지 않은 crossing이 조용히 소비되지 않도록 함.
            if currentSeverity <= previousSeverity || paceFired {
                next.previousBucket = currentBucket
            }
        }

        // 잔여 10% 미만 edge — pace 판정과 독립적으로 추적, 데이터가 있는 모든 상태(pace 또는 `.level`) 대상. 같은 consume-guard 적용.
        let underNow = fraction < 0.10
        let underCrossed = underNow && !next.wasUnderTenPercent
        var underFired = false
        if underCrossed, maybeFire(.underTenPercent, into: &fire, state: &next, toggles: toggles) {
            underFired = true
        }
        if !underNow {
            // 10% 초과 회복 — 이후 하락이 다시 발화하도록 re-arm.
            next.firedMilestones.remove(.underTenPercent)
        }
        if !underCrossed || underFired {
            next.wasUnderTenPercent = underNow
        }

        return Transition(fire: fire, newState: next)
    }

    /// milestone이 이번 pass 발화 후보인지(토글 on, window 내 미발화) 판단 후 `fire`에 추가.
    /// fired 마크는 하지 않음 — dedup 마크는 전달 성공 후에만 호출자가 commit해 실패한 전달이 edge를 소비하지 않도록 함.
    @discardableResult
    private static func maybeFire(
        _ milestone: PaceMilestone,
        into fire: inout [PaceMilestone],
        state: inout NotificationState,
        toggles: PaceNotificationToggles
    ) -> Bool {
        guard toggles.isOn(milestone), !state.firedMilestones.contains(milestone) else { return false }
        fire.append(milestone)
        return true
    }

    /// 전이 비교용 pace 심각도 서수(`untracked`는 `healthy` 아래).
    private static func severity(_ bucket: PaceBucket) -> Int {
        switch bucket {
        case .untracked: return -1
        case .healthy: return 0
        case .close: return 1
        case .runningOut: return 2
        }
    }

    /// reset timestamp의 provider 측 millisecond jitter 허용치 — dedup은 유의미한 전진만 re-arm, UI는 정확한 timestamp 표시 유지.
    static let resetWindowJitterTolerance: TimeInterval = 1

    static func resetWindowAdvanced(resetsAt: Date?, previousReset: Date?) -> Bool {
        guard let resetsAt else { return false }
        guard let previousReset else { return true }
        return resetsAt.timeIntervalSince(previousReset) > resetWindowJitterTolerance
    }
}
