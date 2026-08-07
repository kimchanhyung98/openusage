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
    /// through the family's shared-home runtime instead, so it never gets a duplicate card.
    static func snapshotCards(
        profiles: [AccountProfile],
        preferredProfileIDs: [String: String],
        availableSnapshotProfileIDs: Set<String>
    ) -> [AccountUsageSnapshotCard] {
        profiles.compactMap { profile in
            guard !profile.isArchived,
                  preferredProfileIDs[profile.family] != profile.id,
                  availableSnapshotProfileIDs.contains(profile.id)
            else {
                return nil
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
