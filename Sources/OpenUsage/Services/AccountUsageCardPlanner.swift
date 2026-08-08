import Foundation

/// configuration home이 아닌 계정 credential snapshot 기반 read-only usage 카드.
/// 터미널은 shared home 계속 사용 — 이 카드는 현재 비활성 profile의 대시보드용 안정 소스만 제공.
struct AccountUsageSnapshotCard: Equatable, Sendable {
    let id: String
    let profileID: String
    let family: String
}

enum AccountUsageCardPlanner {
    /// 저장된 credential이 있는 비활성 profile당 snapshot 카드 1개 — 선택 profile은 family의 shared-home runtime으로 렌더.
    /// 단 shared home의 관찰 계정이 다른 identity(외부 re-login)면 선택 profile도 snapshot 카드 부여 — 대시보드 소실 방지.
    static func snapshotCards(
        profiles: [AccountProfile],
        preferredProfileIDs: [String: String],
        availableSnapshotProfileIDs: Set<String>,
        sharedHomeIdentityKeys: [String: String] = [:]
    ) -> [AccountUsageSnapshotCard] {
        profiles.compactMap { profile in
            guard !profile.isArchived,
                  availableSnapshotProfileIDs.contains(profile.id)
            else {
                return nil
            }
            if preferredProfileIDs[profile.family] == profile.id {
                guard let observed = sharedHomeIdentityKeys[profile.family],
                      observed != profile.identityKey
                else { return nil }
            }
            return AccountUsageSnapshotCard(
                id: cardID(family: profile.family, profileID: profile.id),
                profileID: profile.id,
                family: profile.family
            )
        }
    }

    static func cardID(family: String, profileID: String) -> String {
        "\(family)@profile-\(profileID)"
    }
}
