import Foundation
import Observation

/// 모든 전환 화면이 공유하는 실행 상태 — 기존 조회와 전환 후속 작업의 실제 종료까지 유지.
@MainActor
@Observable
final class AccountSwitchCoordinator {
    private(set) var profileID: String?
    var isSwitching: Bool { profileID != nil }
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored private var trackedRefreshes: [UUID: (providerID: String, task: Task<Void, Never>)] = [:]

    static func providerIDs(to profile: AccountProfile, from current: AccountProfile?) -> Set<String> {
        var ids: Set<String> = [profile.family, AccountUsageCardPlanner.cardID(family: profile.family, profileID: profile.id)]
        if let current, current.family == profile.family {
            ids.insert(AccountUsageCardPlanner.cardID(family: current.family, profileID: current.id))
        }
        return ids
    }

    func blocksRefresh(for providerID: String) -> Bool {
        isSwitching && ProviderAccountID.families.contains(ProviderAccountID.family(of: providerID))
    }

    /// 카탈로그 조회의 실행 전·재시도 대기도 추적 — 같은 카드의 동시 요청을 각각 보존.
    func startRefresh(
        providerID: String,
        operation: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            defer { trackedRefreshes[id] = nil }
            await operation()
        }
        trackedRefreshes[id] = (providerID, task)
        return task
    }

    func hasPendingRefreshes(providerIDs: Set<String>) -> Bool {
        trackedRefreshes.values.contains { providerIDs.contains($0.providerID) }
    }

    func waitForRefreshes(providerIDs: Set<String>) async {
        while true {
            let tasks = trackedRefreshes.values.filter { providerIDs.contains($0.providerID) }.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    @discardableResult
    func start(
        profileID: String,
        waitForRefreshes: @escaping @MainActor () async -> Void,
        operation: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never>? {
        guard !isSwitching else { return nil }
        generation &+= 1
        self.profileID = profileID

        // Task 생성 전에 점유 — 이미 열린 다른 화면의 요청도 대기열에 넣지 않고 차단.
        return Task {
            defer { self.profileID = nil }
            await waitForRefreshes()
            do {
                try Task.checkCancellation()
                try await operation()
            } catch {
                onFailure(error)
            }
            await waitForRefreshes()
        }
    }
}
