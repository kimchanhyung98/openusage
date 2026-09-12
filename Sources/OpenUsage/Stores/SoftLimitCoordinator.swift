import Foundation
import Observation

@MainActor
@Observable
final class SoftLimitCoordinator {
    private(set) var statuses: [String: SoftLimitProviderStatus] = [:]
    @ObservationIgnored private let settings: SoftLimitSettingsStore
    @ObservationIgnored private let adapters: [String: any SoftLimitCancelling]
    @ObservationIgnored private let isProviderEnabled: (String) -> Bool
    @ObservationIgnored private let isCancellationScopeVerified: (String) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var observations: [String: SoftLimitObservation] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var finished: Set<SoftLimitTask> = []
    @ObservationIgnored private var retries: [SoftLimitTask: Int] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var observationNotBefore: Date?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(
        settings: SoftLimitSettingsStore,
        adapters: [any SoftLimitCancelling],
        isProviderEnabled: @escaping (String) -> Bool,
        isCancellationScopeVerified: @escaping (String) -> Bool = { _ in false },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.providerID, $0) })
        self.isProviderEnabled = isProviderEnabled
        self.isCancellationScopeVerified = isCancellationScopeVerified
        self.now = now
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                await self.check()
            }
        }
    }

    isolated deinit {
        pollingTask?.cancel()
        for adapter in adapters.values { adapter.disconnect() }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        settingsDidChange()
    }

    func settingsDidChange() {
        revision += 1
        observationNotBefore = now()
        observations.removeAll()
        finished.removeAll()
        retries.removeAll()
        retryAfter.removeAll()
        statuses.removeAll()
        for adapter in adapters.values { adapter.disconnect() }
    }

    func receive(_ snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor]) {
        guard settings.enabled, isProviderEnabled(snapshot.providerID), !snapshot.providerID.contains("@") else { return }
        let providerID = snapshot.providerID
        guard let observation = SoftLimitObservation.project(
            snapshot: snapshot, descriptors: descriptors, window: settings.window, now: now()
        ), observationNotBefore.map({ observation.observedAt >= $0 }) ?? true else {
            observations[providerID] = nil
            statuses[providerID] = .init(phase: .waiting, message: "Waiting for fresh, supported quota data.")
            return
        }
        observations[providerID] = observation
        if observation.usedFraction < Double(settings.thresholdPercent) / 100 {
            finished = finished.filter { $0.providerID != providerID }
            retries = retries.filter { $0.key.providerID != providerID }
            retryAfter[providerID] = nil
            statuses[providerID] = .init(phase: .belowLimit, message: "Below the soft limit. No tasks cancelled.")
        } else if adapters[providerID] == nil {
            statuses[providerID] = .init(phase: .unsupported, message: "Limit reached. Automatic cancellation is not supported for this provider yet.")
        }
    }

    func invalidate(providerID: String) {
        observations[providerID] = nil
        statuses[providerID] = .init(phase: .waiting, message: "Refresh failed. Waiting for fresh quota data before cancelling more tasks.")
    }

    func status(for providerID: String) -> SoftLimitProviderStatus {
        guard adapters[providerID] != nil else {
            return .init(phase: .unsupported, message: "Automatic cancellation is not supported yet.")
        }
        guard isCancellationScopeVerified(providerID) else {
            return .init(phase: .unsupported, message: "Account scope is not verified. Automatic cancellation is unavailable.")
        }
        return statuses[providerID] ?? .init(phase: .waiting, message: "Waiting for the next successful quota refresh.")
    }

    /// 한 번의 제어 조회 — GUI timer와 fresh-success callback만 호출.
    func check() async {
        for providerID in observations.keys.sorted() {
            await check(providerID: providerID)
        }
    }

    func check(providerID: String) async {
        guard let observation = observations[providerID],
              settings.enabled, isProviderEnabled(providerID), isCancellationScopeVerified(providerID),
              observation.usedFraction >= Double(settings.thresholdPercent) / 100
        else { return }
        guard now() < observation.expiresAt else {
            statuses[providerID] = .init(phase: .waiting, message: "Quota data is stale. Waiting for a successful refresh before cancelling more tasks.")
            return
        }
        guard let adapter = adapters[providerID], !inFlight.contains(providerID),
              retryAfter[providerID].map({ now() >= $0 }) ?? true
        else { return }
        inFlight.insert(providerID)
        defer { inFlight.remove(providerID) }
        let boundRevision = revision
        do {
            let tasks = try await adapter.runningTasks()
            guard canCancel(providerID, revision: boundRevision) else { return }
            guard tasks.allSatisfy({ $0.providerID == providerID }) else { throw SoftLimitControlError.wrongProvider }
            let pending = Set(tasks).subtracting(finished)
            if pending.isEmpty {
                if statuses[providerID]?.phase != .cancelled {
                    statuses[providerID] = .init(phase: .noRunningTasks, message: "No running tasks on the connected client. " + adapter.coverageNotice)
                }
                return
            }
            var cancelledCount = statuses[providerID]?.cancelledCount ?? 0
            var failures = 0
            statuses[providerID] = .init(phase: .cancelling, cancelledCount: cancelledCount, message: "Cancelling connected tasks…")
            for task in pending.sorted(by: { ($0.sessionID, $0.operationID) < ($1.sessionID, $1.operationID) }) {
                guard canCancel(providerID, revision: boundRevision) else { return }
                guard retries[task, default: 0] < 3 else { failures += 1; continue }
                do {
                    let outcome = try await adapter.cancel(task) { [weak self] in
                        self?.canCancel(providerID, revision: boundRevision) == true
                    }
                    guard canCancel(providerID, revision: boundRevision) else { return }
                    finished.insert(task)
                    if case .cancelled = outcome { cancelledCount += 1 }
                } catch is CancellationError {
                    return
                } catch {
                    guard canCancel(providerID, revision: boundRevision) else { return }
                    failures += 1
                    retries[task, default: 0] += 1
                    AppLog.error(LogTag.plugin(providerID), "Soft Limit task cancellation failed")
                }
            }
            statuses[providerID] = .init(
                phase: failures == 0 ? .cancelled : .failed,
                cancelledCount: cancelledCount,
                failedCount: failures,
                message: "\(cancelledCount) connected task(s) cancelled. "
                    + (failures > 0 ? "\(failures) cancellation(s) not confirmed. " : "")
                    + adapter.coverageNotice
            )
            if failures > 0 { retryAfter[providerID] = now().addingTimeInterval(10) }
            AppLog.info(LogTag.plugin(providerID), "Soft Limit result: cancelled=\(cancelledCount), failed=\(failures)")
        } catch is CancellationError {
            return
        } catch {
            guard canCancel(providerID, revision: boundRevision) else { return }
            adapter.disconnect()
            let message = (error as? SoftLimitControlError)?.localizedDescription
                ?? "The local cancellation connection failed. Tasks may still be running."
            statuses[providerID] = .init(phase: .failed, message: message)
            retryAfter[providerID] = now().addingTimeInterval(10)
            AppLog.error(LogTag.plugin(providerID), "Soft Limit control connection failed")
        }
    }

    private func canCancel(_ providerID: String, revision expected: Int) -> Bool {
        guard !Task.isCancelled, revision == expected, settings.enabled, isProviderEnabled(providerID),
              isCancellationScopeVerified(providerID),
              let observation = observations[providerID], now() < observation.expiresAt
        else { return false }
        return observation.usedFraction >= Double(settings.thresholdPercent) / 100
    }
}
