import Foundation

/// quota pace-notification subsystem 소유 — metric별 dedup 상태, fire/deliver/commit 결정, debug trace
/// `WidgetDataStore`에서 분리된 독립 관심사 — delivery와 provider 표시명은 closure로 주입
/// metric·reset window 단위 dedup, no-data metric 미발화, 미전달 metric 상태는 prune되어 재등록 시 초기화
@MainActor
final class QuotaNotificationEvaluator {
    /// store가 이미 resolve한 이번 pass의 enabled·bounded·visible metric 하나
    struct Metric {
        let key: String
        let providerID: String
        let data: WidgetData
    }

    private var notificationState: [String: NotificationState] = [:]

    /// 전체 metric의 pace milestone 평가 후 신규 도달분을 `post`로 전달 — `providerName`은 subtitle용 표시명 매핑
    func evaluate(
        metrics: [Metric],
        toggles: PaceNotificationToggles,
        now: Date,
        providerName: @MainActor (String) -> String,
        post: @MainActor (String, String, String, String) async -> Bool
    ) async {
        var nextState: [String: NotificationState] = [:]
        for metric in metrics {
            let key = metric.key
            let data = metric.data
            let state = data.meterState(now: now)
            let previous = notificationState[key] ?? NotificationState()
            let currentBucket = PaceNotificationLogic.bucket(for: state)
            let resetDelta = Self.resetDelta(current: data.resetsAt, previous: previous.resetsAt)
            let resetAdvanced = PaceNotificationLogic.resetWindowAdvanced(
                resetsAt: data.resetsAt,
                previousReset: previous.resetsAt
            )
            let result = PaceNotificationLogic.transitions(
                state: state,
                fraction: data.remainingFraction,
                resetsAt: data.resetsAt,
                previous: previous,
                toggles: toggles
            )
            if !result.fire.isEmpty || resetAdvanced || Self.isPositiveResetMovement(resetDelta) {
                AppLog.debug(.notifications, "decision \(key): metric=\(data.title) state=\(Self.notificationStateDescription(state)) bucket=\(Self.bucketDescription(currentBucket)) previousBucket=\(Self.bucketDescription(previous.previousBucket)) remaining=\(Self.percentDescription(data.remainingFraction)) reset=\(Self.dateDescription(data.resetsAt)) previousReset=\(Self.dateDescription(previous.resetsAt)) resetDelta=\(Self.resetDeltaDescription(resetDelta)) resetReason=\(Self.resetReasonDescription(delta: resetDelta, advanced: resetAdvanced)) primed=\(previous.primed) wasUnderTen=\(previous.wasUnderTenPercent) firedBefore=\(Self.milestoneDescription(previous.firedMilestones)) fire=\(Self.milestoneDescription(result.fire)) newBucket=\(Self.bucketDescription(result.newState.previousBucket)) newFired=\(Self.milestoneDescription(result.newState.firedMilestones)) toggles=\(Self.toggleDescription(toggles))")
            }
            // dedup 상태는 실제 전달 성공분만 commit — 실패·미인가 전달은 상태를 되돌려 다음 pass에 재발화
            var next = result.newState
            var paceDelivered = false
            var underDelivered = false
            for milestone in result.fire {
                let delivered = await deliver(milestone, data: data, providerID: metric.providerID,
                                              providerName: providerName, post: post)
                if delivered {
                    if milestone == .underTenPercent { underDelivered = true } else { paceDelivered = true }
                    next.firedMilestones.insert(milestone)
                }
            }
            if result.fire.contains(where: { $0 != .underTenPercent }) && !paceDelivered {
                next.previousBucket = previous.previousBucket
            }
            if result.fire.contains(.underTenPercent) && !underDelivered {
                next.wasUnderTenPercent = previous.wasUnderTenPercent
            }
            if !result.fire.isEmpty {
                AppLog.debug(.notifications, "commit \(key): paceDelivered=\(paceDelivered) underTenDelivered=\(underDelivered) persistedBucket=\(Self.bucketDescription(next.previousBucket)) persistedWasUnderTen=\(next.wasUnderTenPercent) persistedFired=\(Self.milestoneDescription(next.firedMilestones))")
            }
            nextState[key] = next
        }
        notificationState = nextState
    }

    /// milestone 알림 1건 조립·게시 — title은 trigger명, subtitle은 "Provider Metric", 전달 성공 여부 반환
    private func deliver(
        _ milestone: PaceMilestone,
        data: WidgetData,
        providerID: String,
        providerName: @MainActor (String) -> String,
        post: @MainActor (String, String, String, String) async -> Bool
    ) async -> Bool {
        let subtitle = "\(providerName(providerID)) \(data.title)"
        return await post("\(providerID).\(milestone.rawValue)", milestone.notificationTitle, subtitle, milestone.body)
    }

    // MARK: - Notification decision trace helpers (debug logging only)

    private static func resetDelta(current: Date?, previous: Date?) -> TimeInterval? {
        guard let current, let previous else { return nil }
        return current.timeIntervalSince(previous)
    }

    private static func isPositiveResetMovement(_ delta: TimeInterval?) -> Bool {
        guard let delta else { return false }
        return delta > 0
    }

    private static func resetReasonDescription(delta: TimeInterval?, advanced: Bool) -> String {
        guard let delta else { return "firstOrMissingReset" }
        if advanced { return "advanced" }
        if delta > 0 { return "ignoredJitter" }
        if delta < 0 { return "movedEarlier" }
        return "unchanged"
    }

    private static func resetDeltaDescription(_ delta: TimeInterval?) -> String {
        guard let delta else { return "nil" }
        return String(format: "%.3fs", delta)
    }

    private static func dateDescription(_ date: Date?) -> String {
        date.map { OpenUsageISO8601.string(from: $0) } ?? "nil"
    }

    private static func percentDescription(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func toggleDescription(_ toggles: PaceNotificationToggles) -> String {
        "under10=\(toggles.underTenPercent),close=\(toggles.healthyToClose),runOut=\(toggles.closeToRunningOut)"
    }

    private static func milestoneDescription(_ milestones: Set<PaceMilestone>) -> String {
        milestoneDescription(milestones.sorted { $0.rawValue < $1.rawValue })
    }

    private static func milestoneDescription(_ milestones: [PaceMilestone]) -> String {
        guard !milestones.isEmpty else { return "[]" }
        return "[" + milestones.map(\.rawValue).joined(separator: ",") + "]"
    }

    private static func bucketDescription(_ bucket: PaceBucket) -> String {
        switch bucket {
        case .untracked: return "untracked"
        case .healthy: return "healthy"
        case .close: return "close"
        case .runningOut: return "runningOut"
        }
    }

    private static func notificationStateDescription(_ state: WidgetData.MeterState) -> String {
        switch state {
        case .noData: return "noData"
        case .spent: return "spent"
        case .runningOut: return "runningOut"
        case .closeToLimit: return "closeToLimit"
        case .healthy: return "healthy"
        case .level(let severity):
            switch severity {
            case .neutral: return "level.neutral"
            case .normal: return "level.normal"
            case .warning: return "level.warning"
            case .critical: return "level.critical"
            }
        }
    }
}
