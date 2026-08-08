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

    /// Settings 관리 profile 기반 card만 선택된 하나로 축약
    /// 독립 발견된 config-directory card는 managed profile에 연결되기 전까지 일반 card로 유지
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

    /// 계정 전환 확정 후 dashboard 선택을 family 공유 runtime으로 지정
    /// 구 credential 사본을 들고 있을 수 있는 ambient config-dir card 대신 bare runtime을 가리키는 규칙
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
