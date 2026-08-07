import Foundation

/// A read-only usage card backed by an account credential snapshot rather than a configuration home.
/// The terminal keeps using the shared home; this card only gives the dashboard a stable source for a
/// profile that is currently inactive there.
struct AccountUsageSnapshotCard: Equatable, Sendable {
    let id: String
    let profileID: String
    let family: String
}

enum AccountUsageCardPlanner {
    /// One snapshot card per inactive profile with a saved credential. The selected profile renders
    /// through the family's shared-home runtime instead — but only while that home actually serves
    /// it: when the home's observed account is a different identity (an external re-login), the
    /// selected profile gets a snapshot card too, or it would vanish from the dashboard entirely.
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
