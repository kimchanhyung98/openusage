import Foundation

/// 공개 리셋 예측·예정의 전역 알림 — 계정 수와 무관하게 이벤트별 전달 기록 유지.
@MainActor
final class CodexResetWatchNotificationEvaluator {
    static let settingLabel = "Codex Reset Watch"
    private static let deliveredKey = "openusage.notifications.codexResetWatch.delivered.v1"

    typealias Post = @MainActor (String, String, String, String, @MainActor () -> Bool) async -> Bool

    private let defaults: UserDefaults
    let isEnabled: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let post: Post
    private var deliveredIDs: [String]
    private var enabled: Bool
    private var generation = 0
    private var latestResult = CodexResetWatchResult()
    private var needsEvaluation = false
    private var deliveryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        isEnabled: @escaping @MainActor () -> Bool,
        now: @escaping @MainActor () -> Date = Date.init,
        post: @escaping Post = { id, title, subtitle, body, isCurrent in
            await AppNotifications.shared.post(
                idPrefix: id, title: title, subtitle: subtitle, body: body, isCurrent: isCurrent
            )
        }
    ) {
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.now = now
        self.post = post
        self.deliveredIDs = defaults.stringArray(forKey: Self.deliveredKey) ?? []
        self.enabled = isEnabled()
    }

    /// 빠른 off→on도 이전 전달을 되살리지 않도록 설정 변경 시 동기 무효화.
    func configurationDidChange() {
        let current = isEnabled()
        guard current != enabled else { return }
        enabled = current
        generation &+= 1
        latestResult = CodexResetWatchResult()
        needsEvaluation = false
    }

    /// 전달 중 도착한 결과는 최신 값으로 병합하며, 실패한 전달은 다음 조회에서 재시도.
    @discardableResult
    func receive(_ result: CodexResetWatchResult) -> Task<Void, Never> {
        configurationDidChange()
        latestResult = result
        if isEnabled(), !result.refreshFailed, !result.refreshCancelled,
           let watch = result.watch, watch.eventID == nil {
            AppLog.warn(.notifications, "Skipping Codex Reset Watch notification: event identity unavailable")
        }
        needsEvaluation = true
        if let deliveryTask { return deliveryTask }
        let task = Task<Void, Never> { [weak self] in
            await self?.evaluatePendingResults()
        }
        deliveryTask = task
        return task
    }

    private func evaluatePendingResults() async {
        defer { deliveryTask = nil }
        while needsEvaluation, !Task.isCancelled {
            needsEvaluation = false
            guard let watch = candidate() else { continue }
            let identifiers = eventIDs(for: watch)
            if !identifiers.isDisjoint(with: deliveredIDs) {
                remember(identifiers)
                continue
            }
            let deliveryGeneration = generation
            let delivered = await post(
                "codex.resetWatch", Self.settingLabel,
                watch.isScheduled ? "Scheduled Reset" : "Reset Forecast",
                watch.isScheduled
                    ? "A community report lists an upcoming Codex reset."
                    : "A new community forecast for a Codex reset is available."
            ) { [self] in
                !Task.isCancelled && generation == deliveryGeneration
                    && candidate().map { !eventIDs(for: $0).isDisjoint(with: identifiers) } == true
            }
            guard delivered, generation == deliveryGeneration, let current = candidate(),
                  !eventIDs(for: current).isDisjoint(with: identifiers) else { continue }
            remember(identifiers.union(eventIDs(for: current)))
        }
    }

    private func eventIDs(for watch: CodexResetWatch) -> Set<String> {
        Set([watch.eventID].compactMap { $0 } + watch.eventAliases)
    }

    private func remember(_ identifiers: Set<String>) {
        let previous = deliveredIDs.filter { !identifiers.contains($0) }
        let updated = Array((previous + identifiers.sorted()).suffix(128))
        guard updated != deliveredIDs else { return }
        deliveredIDs = updated
        defaults.set(deliveredIDs, forKey: Self.deliveredKey)
    }

    private func candidate() -> CodexResetWatch? {
        guard isEnabled(), !latestResult.refreshFailed, !latestResult.isAbsent,
              !latestResult.refreshCancelled,
              let watch = latestResult.watch, let eventID = watch.eventID, !eventID.isEmpty,
              watch.chancePercent > 0, !watch.isExpired(at: now()) else { return nil }
        if let deadline = watch.deadline, deadline <= now() { return nil }
        return watch
    }
}
