import Foundation

/// 기존 runtime 결과를 변경하지 않고 화면에 쓸 계정 카드 순서·표시 대상만 계산.
enum AccountCardPresentationPlanner {
    /// 등록 이름은 변경하지 않고 이름이 겹친 미등록 공유 홈만 구분.
    static func unmanagedAccountName(_ name: String, reservedNames: [String]) -> String {
        let reserved = Set(reservedNames.map { $0.lowercased() })
        guard reserved.contains(name.lowercased()) else { return name }
        let base = "\(name) (Shared Home)"
        var candidate = base
        var suffix = 2
        while reserved.contains(candidate.lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func cardTitle(
        providerID: String,
        fallback: String,
        mode: AccountCardDisplayMode,
        accountName: String
    ) -> String {
        let family = ProviderAccountID.family(of: providerID)
        guard ProviderAccountID.families.contains(family), mode == .separateCards else {
            return ProviderAccountID.cardTitle(providerID: providerID, fallback: fallback)
        }
        return "\(family.capitalized): \(accountName)"
    }

    static func orderedCardIDs(
        _ cardIDs: [String],
        familyOrder: [String],
        orderedProfileIDsByFamily: [String: [String]],
        profileIDsByCardID: [String: String]
    ) -> [String] {
        let cardsByFamily = Dictionary(grouping: cardIDs, by: groupingID)
        var seen = Set<String>()
        let orderedFamilies = (familyOrder + cardIDs).map(groupingID).filter {
            cardsByFamily[$0] != nil && seen.insert($0).inserted
        }
        return orderedFamilies.flatMap { family -> [String] in
            let cards = cardsByFamily[family] ?? []
            guard ProviderAccountID.families.contains(family) else { return cards }
            let profileOrder = orderedProfileIDsByFamily[family] ?? []
            return cards.enumerated().sorted { lhs, rhs in
                let left = profileIDsByCardID[lhs.element].flatMap { profileOrder.firstIndex(of: $0) }
                let right = profileIDsByCardID[rhs.element].flatMap { profileOrder.firstIndex(of: $0) }
                if left != right { return (left ?? Int.max) < (right ?? Int.max) }
                return lhs.offset < rhs.offset
            }.map(\.element)
        }
    }

    static func presentedCardIDs(
        orderedCardIDs: [String],
        modesByFamily: [String: AccountCardDisplayMode],
        selectedCardIDsByFamily: [String: String]
    ) -> [String] {
        var selected: [String: String] = [:]
        for family in ProviderAccountID.families where modesByFamily[family] != .separateCards {
            let cards = orderedCardIDs.filter { ProviderAccountID.family(of: $0) == family }
            if let stored = selectedCardIDsByFamily[family], cards.contains(stored) {
                selected[family] = stored
            } else {
                selected[family] = cards.contains(family) ? family : cards.first
            }
        }
        return orderedCardIDs.filter { cardID in
            let family = ProviderAccountID.family(of: cardID)
            return selected[family].map { $0 == cardID } ?? true
        }
    }

    /// 공유 홈 runtime만 로컬 통계 보유 — 비활성 snapshot의 빈 통계 행은 분리 카드에서 제외.
    static func presentedGroup(_ group: ProviderGroup, mode: AccountCardDisplayMode) -> ProviderGroup? {
        guard mode == .separateCards,
              ProviderAccountID.families.contains(ProviderAccountID.family(of: group.id)),
              ProviderAccountID.isAccountCard(group.id)
        else { return group }
        let hiddenIDs = Set(["trend", "today", "yesterday"].map { "\(group.id).\($0)" })
        let alwaysShown = group.alwaysShownWidgets.filter { !hiddenIDs.contains($0.descriptorID) }
        let expanded = group.expandedWidgets.filter { !hiddenIDs.contains($0.descriptorID) }
        guard !alwaysShown.isEmpty || !expanded.isEmpty else { return nil }
        return ProviderGroup(
            provider: group.provider,
            alwaysShownWidgets: alwaysShown.isEmpty ? expanded : alwaysShown,
            expandedWidgets: alwaysShown.isEmpty ? [] : expanded
        )
    }

    private static func groupingID(_ cardID: String) -> String {
        let family = ProviderAccountID.family(of: cardID)
        return ProviderAccountID.families.contains(family) ? family : cardID
    }
}
