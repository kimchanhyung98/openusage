import Foundation

enum DashboardUsageAccountSelection {
    static let claudeKey = "openusage.dashboardUsageAccount.claude"
    static let codexKey = "openusage.dashboardUsageAccount.codex"

    /// 등록 계정은 현재 runtime 대신 stable profile로 저장 — 미등록·기존 runtime 선택은 그대로 유지.
    static func selectionID(for providerID: String, family: String, profileID: String?) -> String {
        profileID.map { AccountUsageCardPlanner.cardID(family: family, profileID: $0) } ?? providerID
    }

    static func select(
        _ providerID: String,
        for family: String,
        profileID: String? = nil,
        defaults: UserDefaults = .standard
    ) {
        guard let key = key(for: family) else { return }
        defaults.set(selectionID(for: providerID, family: family, profileID: profileID), forKey: key)
    }

    static func selectedID(for family: String, defaults: UserDefaults = .standard) -> String {
        guard let key = key(for: family) else { return "" }
        return defaults.string(forKey: key) ?? ""
    }

    /// 저장된 family별 선택 — dashboard는 `@AppStorage`로 관찰하고, 메뉴 바는 렌더마다 이걸 읽음
    static func storedSelections(defaults: UserDefaults = .standard) -> [String: String] {
        var result: [String: String] = [:]
        for family in AccountProfilesStore.supportedFamilies {
            result[family] = selectedID(for: family, defaults: defaults)
        }
        return result
    }

    /// 저장된 profile 선택을 현재 표시 카드로 해석 — 실시간·스냅샷 전환 시 저장값 변경 없음.
    static func visibleCardID(
        for family: String,
        among cardIDs: [String],
        stored: String,
        preferredCardID: String?,
        profileIDsByCardID: [String: String]
    ) -> String? {
        guard let first = cardIDs.first else { return nil }
        if cardIDs.contains(stored) { return stored }
        if let replacement = cardIDs.first(where: { cardID in
            guard let profileID = profileIDsByCardID[cardID] else { return false }
            return AccountUsageCardPlanner.cardID(family: family, profileID: profileID) == stored
        }) {
            return replacement
        }
        if let preferredCardID { return preferredCardID }
        return cardIDs.contains(family) ? family : first
    }

    /// family의 모든 card를 선택된 하나로 축약 — 등록 계정도 독립 발견된 config-directory 로그인도 동일 취급
    /// 대시보드에는 provider당 card 1장만 남고, 나머지 계정은 header selector 항목이 됨
    static func visibleCardIDs(
        orderedCardIDs: [String],
        familyCardIDs: Set<String>,
        selectedCardID: String?
    ) -> [String] {
        guard familyCardIDs.count > 1,
              let selectedCardID,
              familyCardIDs.contains(selectedCardID)
        else {
            return orderedCardIDs
        }
        return orderedCardIDs.filter {
            !familyCardIDs.contains($0) || $0 == selectedCardID
        }
    }

    /// selector 항목 이름 — 등록 계정은 계정명, 자동 발견 계정은 파생 이름에서 provider 접두를 뗀 부분,
    /// 공유 home 계정은 "Default". 카드 제목은 provider 고정이라 계정 구분은 여기서만 드러남
    static func optionTitle(cardID: String, profileLabel: String?, accountName: String?) -> String {
        if let label = profileLabel?.nilIfEmpty { return label }
        guard ProviderAccountID.isAccountCard(cardID) else { return "Default" }
        guard let accountName = accountName?.nilIfEmpty else { return cardID }
        let prefix = "\(ProviderAccountID.family(of: cardID).capitalized) — "
        return accountName.hasPrefix(prefix) ? String(accountName.dropFirst(prefix.count)) : accountName
    }

    /// 계정 전환 확정 후 선택 profile을 저장하고, 즉시 새로 고칠 공유 runtime ID 반환.
    /// 구 credential 사본을 들고 있을 수 있는 ambient config-dir card는 새로 고침 대상으로 사용하지 않음.
    @discardableResult
    static func selectAfterAccountSwitch(
        family: String,
        profileID: String,
        availableCardIDs: [String],
        defaults: UserDefaults = .standard
    ) -> String? {
        guard key(for: family) != nil, availableCardIDs.contains(family) else {
            AppLog.error(.config, "account switch could not select the shared \(family) usage runtime")
            return nil
        }
        select(family, for: family, profileID: profileID, defaults: defaults)
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
