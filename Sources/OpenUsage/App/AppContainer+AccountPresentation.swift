import Foundation

extension AppContainer {
    func orderedAccountProfiles(for family: String) -> [AccountProfile] {
        accountCardPresentation.orderedProfiles(accountProfiles.profiles(family: family), family: family)
    }

    func accountCardDisplayMode(for family: String) -> AccountCardDisplayMode {
        accountCardPresentation.effectiveMode(
            for: family,
            profiles: accountProfiles.profiles(family: family),
            registryReadable: !accountProfiles.hasUnreadableRegistry
        )
    }

    /// 순서는 표시 전용 — 런타임 catalog·CLI·HTTP API의 순서와 무관.
    func orderedAccountCardIDs(_ cardIDs: [String]) -> [String] {
        let profileOrders = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.map {
            ($0, orderedAccountProfiles(for: $0).map(\.id))
        })
        let profileMapping = Dictionary(uniqueKeysWithValues: cardIDs.compactMap { cardID in
            accountProfileID(for: cardID).map { (cardID, $0) }
        })
        return AccountCardPresentationPlanner.orderedCardIDs(
            cardIDs,
            familyOrder: layout.customizeProviderRows.map(\.id),
            orderedProfileIDsByFamily: profileOrders,
            profileIDsByCardID: profileMapping
        )
    }

    /// Dashboard·Share가 동일한 최종 카드 목록을 사용하며 선택 fallback은 기존 규칙 유지.
    func presentedAccountGroups(selectionByFamily: [String: String]? = nil) -> [ProviderGroup] {
        _ = accountSelectionRevision
        let selections = selectionByFamily ?? DashboardUsageAccountSelection.storedSelections()
        let groups = layout.displayGroups
        let rawIDs = groups.map(\.provider.id)
        let selectedIDs = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.compactMap { family in
            visibleAccountCardID(
                for: family,
                among: accountCardIDs(for: family, among: rawIDs),
                stored: selections[family] ?? ""
            ).map { (family, $0) }
        })
        let modes = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.map {
            ($0, accountCardDisplayMode(for: $0))
        })
        let presentedIDs = AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: orderedAccountCardIDs(rawIDs),
            modesByFamily: modes,
            selectedCardIDsByFamily: selectedIDs
        )
        let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.provider.id, $0) })
        return presentedIDs.compactMap { groupsByID[$0] }
    }

    func accountCardTitle(for provider: Provider) -> String {
        let family = ProviderAccountID.family(of: provider.id)
        let name = accountOptionTitle(for: provider.id)
        let resolvedName = accountProfileLabel(for: provider.id) == nil
            ? AccountCardPresentationPlanner.unmanagedAccountName(
                name,
                reservedNames: accountProfiles.profiles(family: family).map(\.label)
            )
            : name
        return AccountCardPresentationPlanner.cardTitle(
            providerID: provider.id,
            fallback: displayName(for: provider),
            mode: accountCardDisplayMode(for: family),
            accountName: resolvedName
        )
    }
}
