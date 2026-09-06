import Foundation
import Observation

/// Codex usage와 독립된 Reset Watch 활성 상태·15분 조회 주기 소유자.
@MainActor
final class CodexResetWatchCoordinator {
    static let refreshInterval = RefreshSetting.interval * 3

    typealias Waiting = @Sendable (Duration) async -> Bool

    private let load: CodexResetWatchLoading
    private let publish: @MainActor (CodexResetWatchResult) -> Void
    private let interval: Duration
    private let wait: Waiting
    private var isActive = false
    private var task: Task<Void, Never>?

    init(
        load: @escaping CodexResetWatchLoading,
        publish: @escaping @MainActor (CodexResetWatchResult) -> Void,
        interval: Duration = .seconds(CodexResetWatchCoordinator.refreshInterval),
        wait: @escaping Waiting = { duration in
            do {
                try await Task.sleep(for: duration)
                return true
            } catch {
                return false
            }
        }
    ) {
        self.load = load
        self.publish = publish
        self.interval = interval
        self.wait = wait
    }

    deinit { task?.cancel() }

    /// 배치·pin·enablement의 활성 조건을 관찰하고 변경 뒤 관찰을 다시 등록.
    func observeActivity(_ active: @escaping @MainActor () -> Bool) {
        let value = withObservationTracking(active) { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeActivity(active)
            }
        }
        setActive(value)
    }

    /// 활성 전환 시 즉시 조회 후 독립 주기 반복, 비활성 전환 시 표시 값과 예약 작업 제거.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        task?.cancel()
        task = nil

        guard active else {
            publish(CodexResetWatchResult())
            return
        }

        let load = self.load
        let publish = self.publish
        let interval = self.interval
        let wait = self.wait
        task = Task {
            while !Task.isCancelled {
                let watch = await load()
                guard !Task.isCancelled else { return }
                publish(watch)
                guard await wait(interval), !Task.isCancelled else { return }
            }
        }
    }
}
