import XCTest
@testable import OpenUsage

/// 계정 카드 layout은 provider(family) 설정 1벌을 공유 — 카드별 사본 없음
@MainActor
final class AccountCardLayoutSharingTests: XCTestCase {
    private let cardID = "claude@profile-work"

    func testAnAccountCardKeepsTheProvidersOnDemandSplit() {
        // 저장된 caret 소속에 family id만 있고 카드가 나중에 등장한 설치 — 카드 행이 fold 위로 새지 않아야 함
        let defaults = makeDefaults("OnDemandSplit")
        defaults.set(["claude.trend", "claude.today"], forKey: "layout.expandedMetrics")
        saveStored(["claude.session", "claude.trend", "claude.today"], forKey: "layout.seededDefaults", in: defaults)

        let store = makeStore(defaults: defaults)

        let group = store.displayGroups.first { $0.provider.id == cardID }
        XCTAssertEqual(group?.alwaysShownWidgets.map(\.descriptorID), ["\(cardID).session"])
        XCTAssertEqual(
            group?.expandedWidgets.map(\.descriptorID),
            ["\(cardID).trend", "\(cardID).today"],
            "the card follows the provider's Always Visible / On Demand split"
        )
    }

    func testHidingAMetricFromAnAccountCardHidesItOnEveryCard() {
        let store = makeStore(defaults: makeDefaults("HideEverywhere"))
        XCTAssertTrue(store.isMetricEnabled("claude.trend"))

        store.setMetricEnabled("\(cardID).trend", false)

        XCTAssertFalse(store.isMetricEnabled("claude.trend"))
        XCTAssertFalse(store.isMetricEnabled("\(cardID).trend"))
        XCTAssertFalse(
            store.placed.contains { ProviderAccountID.isAccountCard($0.descriptorID) },
            "enabled metrics are stored once per provider"
        )
    }

    func testExpandingAnAccountCardExpandsTheWholeProvider() {
        let store = makeStore(defaults: makeDefaults("ExpandShared"))

        XCTAssertTrue(store.setProviderExpanded(true, for: cardID))

        XCTAssertTrue(store.isProviderExpanded("claude"))
        XCTAssertTrue(store.isProviderExpanded(cardID))
    }

    func testMovingAMetricOnAnAccountCardMovesItForTheProvider() {
        let store = makeStore(defaults: makeDefaults("ReorderShared"))
        store.expandedMetricIDs = ["claude.trend"]

        XCTAssertTrue(store.reorderMetric(dragged: "\(cardID).today", target: "\(cardID).trend", in: cardID))

        XCTAssertTrue(store.expandedMetricIDs.contains("claude.today"), "the drag writes the family entry")
        XCTAssertFalse(store.expandedMetricIDs.contains { ProviderAccountID.isAccountCard($0) })
        XCTAssertEqual(
            store.displayGroups.first { $0.provider.id == "claude" }?.expandedWidgets.map(\.descriptorID),
            ["claude.today", "claude.trend"],
            "dragging up lands the metric above its target for every card"
        )
    }

    func testEveryCardsMetricsFeedRefreshAndNotifications() {
        let store = makeStore(defaults: makeDefaults("RenderedDescriptors"))

        let ids = store.orderedRenderedDescriptors().map(\.id)

        XCTAssertTrue(ids.contains("claude.session"))
        XCTAssertTrue(
            ids.contains("\(cardID).session"),
            "an account card's metrics must still reach quota notifications"
        )
    }

    func testReorderingAProviderMovesItsWholeAccountBlock() {
        let store = makeStore(defaults: makeDefaults("ReorderFamilyBlock"))
        store.providerOrder = ["claude", cardID, "codex"]

        XCTAssertTrue(store.reorderProvider(dragged: "codex", target: "claude"))

        XCTAssertEqual(
            store.providerOrder,
            ["codex", "claude", cardID],
            "accounts of a provider stay together, so switching accounts never moves the section"
        )
    }

    // MARK: - Migration of layouts saved per account card

    func testStoredAccountCardEntriesFoldIntoTheProviderLayout() {
        let defaults = makeDefaults("FoldStoredEntries")
        saveStored(
            [
                PlacedWidget(descriptorID: "claude.session"),
                PlacedWidget(descriptorID: "\(cardID).session"),
                PlacedWidget(descriptorID: "\(cardID).trend"),
            ],
            forKey: "layout",
            in: defaults
        )
        defaults.set(["claude.trend", "\(cardID).today"], forKey: "layout.expandedMetrics")
        defaults.set([cardID], forKey: "layout.expandedProviders")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session", "claude.trend"])
        XCTAssertEqual(store.expandedMetricIDs, ["claude.trend"], "card entries lose to the provider's own setting")
        XCTAssertEqual(store.expandedProviderIDs, ["claude"])

        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        XCTAssertEqual(persistence.loadPlaced()?.map(\.descriptorID), ["claude.session", "claude.trend"])
        XCTAssertEqual(persistence.loadExpandedMetrics().map(Set.init), ["claude.trend"])
        XCTAssertEqual(persistence.loadExpandedProviders().map(Set.init), ["claude"])
    }

    func testACardOnlyCaretSplitIsPromotedInsteadOfDropped() {
        // 카드 화면에서만 caret을 편집한 설치 — family 항목이 없으면 그 선택이 provider 설정이 됨
        let defaults = makeDefaults("PromoteCardOnlyExpansion")
        defaults.set(["\(cardID).trend"], forKey: "layout.expandedMetrics")
        defaults.set(["\(cardID).today"], forKey: "layout.expandOnEnable")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.expandedMetricIDs, ["claude.trend"], "the card's split is kept as the provider's")
        XCTAssertEqual(store.defaultExpandedOnEnableIDs, ["claude.today"])
    }

    func testAFamilyCaretSplitWinsOverCardEntries() {
        let defaults = makeDefaults("FamilyExpansionWins")
        defaults.set(["claude.trend", "\(cardID).today"], forKey: "layout.expandedMetrics")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(
            store.expandedMetricIDs,
            ["claude.trend"],
            "once the provider has its own entry, card copies are dropped"
        )
    }

    func testFoldingStarsIsDeterministicWithoutARanking() {
        let pins = ["claude.today", "claude.trend", "claude.session"]

        let first = LayoutOrdering.foldingPins(pins, order: [:], limit: 2)
        let second = LayoutOrdering.foldingPins(pins.reversed(), order: [:], limit: 2)

        XCTAssertEqual(first, ["claude.today", "claude.trend"], "with no ranking the saved order decides")
        XCTAssertEqual(second, ["claude.session", "claude.trend"])
    }

    func testFoldedMenuBarStarsStayWithinThePerProviderLimit() {
        let defaults = makeDefaults("FoldStars")
        defaults.set(
            ["\(cardID).today", "claude.session", "\(cardID).trend"],
            forKey: "layout.menuBarPins"
        )

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(
            store.pinnedMetricIDs,
            ["claude.session", "claude.trend"],
            "folding three card stars keeps the first two in metric order"
        )
        XCTAssertEqual(
            LayoutPersistence(defaults: defaults, storageKey: "layout").loadPins().map(Set.init),
            ["claude.session", "claude.trend"]
        )
    }

    // MARK: - Fixtures

    private func makeStore(defaults: UserDefaults) -> LayoutStore {
        LayoutStore(
            registry: .claudeWithAccountCard,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.trend", "claude.today"],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: ["claude.trend", "claude.today"]
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.AccountCardLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// 기본 Claude 카드 + 등록 계정 카드 하나(+ 순서 검증용 Codex) — 카드들이 같은 metric 3종을 제공
    static var claudeWithAccountCard: WidgetRegistry {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let card = Provider(id: "claude@profile-work", displayName: "Claude — Work", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        func descriptors(_ provider: Provider) -> [WidgetDescriptor] {
            ["session", "trend", "today"].map { suffix in
                WidgetDescriptor(
                    id: "\(provider.id).\(suffix)",
                    providerID: provider.id,
                    metricLabel: suffix,
                    sample: WidgetData(
                        title: suffix,
                        icon: provider.icon,
                        kind: .percent,
                        used: 0,
                        limit: 100
                    )
                )
            }
        }
        return WidgetRegistry(
            providers: [claude, card, codex],
            descriptors: descriptors(claude) + descriptors(card) + descriptors(codex)
        )
    }
}
