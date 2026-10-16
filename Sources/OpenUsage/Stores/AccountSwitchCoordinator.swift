import Foundation
import Observation

/// 모든 전환 화면이 공유하는 실행 상태 — 기존 조회와 전환 후속 작업의 실제 종료까지 유지.
@MainActor
@Observable
final class AccountSwitchCoordinator {
    private(set) var profileID: String?
    var isSwitching: Bool { profileID != nil }

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

    @discardableResult
    func start(
        profileID: String,
        waitForRefreshes: @escaping @MainActor () async -> Void,
        operation: @escaping @MainActor () async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) -> Task<Void, Never>? {
        guard !isSwitching else { return nil }
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
