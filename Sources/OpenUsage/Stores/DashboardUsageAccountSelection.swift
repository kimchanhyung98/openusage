import Foundation

enum DashboardUsageAccountSelection {
    static let claudeKey = "openusage.dashboardUsageAccount.claude"
    static let codexKey = "openusage.dashboardUsageAccount.codex"

    static func select(_ providerID: String, for family: String, defaults: UserDefaults = .standard) {
        guard let key = key(for: family) else { return }
        defaults.set(providerID, forKey: key)
    }

    static func selectedID(for family: String, defaults: UserDefaults = .standard) -> String {
        guard let key = key(for: family) else { return "" }
        return defaults.string(forKey: key) ?? ""
    }

    /// Collapse only cards backed by Settings-managed profiles. Existing config-directory cards
    /// that were discovered independently remain ordinary dashboard cards unless their identity is
    /// attached to a managed profile.
    static func visibleCardIDs(
        orderedCardIDs: [String],
        managedCardIDs: Set<String>,
        selectedManagedCardID: String?
    ) -> [String] {
        guard managedCardIDs.count > 1,
              let selectedManagedCardID,
              managedCardIDs.contains(selectedManagedCardID)
        else {
            return orderedCardIDs
        }
        return orderedCardIDs.filter {
            !managedCardIDs.contains($0) || $0 == selectedManagedCardID
        }
    }

    /// A confirmed Settings switch applies the selected authentication to the family's shared
    /// runtime home. Point the dashboard at that bare runtime rather than an ambient config-dir
    /// card that may still hold an older copy of the same account's rotating credential.
    @discardableResult
    static func selectAfterAccountSwitch(
        family: String,
        availableCardIDs: [String],
        defaults: UserDefaults = .standard
    ) -> String? {
        guard key(for: family) != nil, availableCardIDs.contains(family) else {
            AppLog.error(.config, "account switch could not select the shared \(family) usage runtime")
            return nil
        }
        select(family, for: family, defaults: defaults)
        return family
    }

    private static func key(for family: String) -> String? {
        switch family {
        case "claude": claudeKey
        case "codex": codexKey
        default: nil
        }
    }
}
