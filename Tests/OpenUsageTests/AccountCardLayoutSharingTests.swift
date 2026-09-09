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

    func testProviderReorderIncludesANewAccountRuntimeInTheFamilyBlockAndPinnedOrdinal() {
        let defaults = makeDefaults("ReorderNewAccountRuntime")
        saveStored(["claude", "codex", "cursor"], forKey: "layout.providerOrder", in: defaults)
        let snapshotID = "claude@profile-b"
        let providers = [
            Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude")),
            Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex")),
            Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor")),
            Provider(id: snapshotID, displayName: "Claude — B", icon: .providerMark("claude")),
        ]
        let descriptors = providers.map { provider in
            WidgetDescriptor(
                id: "\(provider.id).session",
                providerID: provider.id,
                metricLabel: "session",
                sample: WidgetData(
                    title: "session",
                    icon: provider.icon,
                    kind: .percent,
                    used: 0,
                    limit: 100
                )
            )
        }
        let store = LayoutStore(
            registry: WidgetRegistry(providers: providers, descriptors: descriptors),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "codex.session", "cursor.session"],
            migrationBaselineMetricIDs: ["claude.session", "codex.session", "cursor.session"],
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: []
        )
        for metricID in ["claude.session", "codex.session", "cursor.session"] {
            store.setPinned(true, for: metricID)
        }

        XCTAssertEqual(store.providerOrder, ["claude", "codex", "cursor"])
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        XCTAssertEqual(store.providerOrder, ["cursor", "claude", snapshotID, "codex"])
        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["cursor", "claude", snapshotID, "codex"])
        let menuBarIDs = DashboardUsageAccountSelection.visibleCardIDs(
            orderedCardIDs: store.pinnedGroups.map(\.provider.id),
            familyCardIDs: ["claude", snapshotID],
            selectedCardID: snapshotID
        )
        XCTAssertEqual(menuBarIDs, ["cursor", snapshotID, "codex"])
        XCTAssertEqual(menuBarIDs.firstIndex(of: snapshotID), 1)
    }

    func testProviderReorderUsesCustomizeOrderWithoutChangingAccountOrder() {
        let defaults = makeDefaults("CanonicalProviderOrder")
        let layout = makeStore(defaults: defaults)
        layout.providerOrder = [cardID, "codex", "claude"]

        let company = AccountProfile(
            id: "company",
            family: "claude",
            label: "company",
            identityKey: "acct-company",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let work = AccountProfile(
            id: "work",
            family: "claude",
            label: "work",
            identityKey: "acct-work",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let profiles = [company, work]
        let presentation = AccountCardPresentationStore(defaults: defaults)
        XCTAssertTrue(presentation.reorder(
            dragged: work.id,
            target: company.id,
            family: "claude",
            profiles: profiles
        ))
        let accountOrder = presentation.orderedProfiles(profiles, family: "claude").map(\.id)

        XCTAssertEqual(layout.customizeProviderRows.map(\.id), ["codex", "claude"])
        XCTAssertTrue(layout.reorderProvider(dragged: "claude", target: "codex"))

        XCTAssertEqual(layout.customizeProviderRows.map(\.id), ["claude", "codex"])
        XCTAssertEqual(layout.providerOrder, [cardID, "claude", "codex"])
        XCTAssertEqual(
            presentation.orderedProfiles(profiles, family: "claude").map(\.id),
            accountOrder,
            "provider-family movement must not rewrite the separately persisted account order"
        )
    }

    func testAccountPresentationChangesDoNotMutateLayoutOrDashboardSelection() {
        let defaults = makeDefaults("PresentationIsolation")
        let codexCardID = "codex@profile-sub"
        saveStored(["codex", codexCardID, "claude", cardID], forKey: "layout.providerOrder", in: defaults)
        let layout = makeStore(defaults: defaults, includesCodexAccountCard: true)
        layout.setMetricEnabled("codex.session", true)
        layout.setMetricEnabled("codex.trend", true)
        layout.setPinned(true, for: "claude.session")
        layout.setPinned(true, for: "codex.session")
        XCTAssertTrue(layout.setProviderExpanded(true, for: "claude"))
        XCTAssertTrue(layout.setProviderExpanded(true, for: "codex"))
        DashboardUsageAccountSelection.select(cardID, for: "claude", defaults: defaults)
        DashboardUsageAccountSelection.select(codexCardID, for: "codex", defaults: defaults)

        let company = AccountProfile(
            id: "company",
            family: "claude",
            label: "company",
            identityKey: "acct-company",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let work = AccountProfile(
            id: "work",
            family: "claude",
            label: "work",
            identityKey: "acct-work",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let personal = AccountProfile(
            id: "personal",
            family: "codex",
            label: "personal",
            identityKey: "acct-personal",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let sub = AccountProfile(
            id: "sub",
            family: "codex",
            label: "sub",
            identityKey: "acct-sub",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let profiles = [company, work, personal, sub]
        let providerOrder = layout.providerOrder
        let placed = layout.placed
        let metricOrder = layout.metricOrderByProvider
        let pins = layout.pinnedMetricIDs
        let expandedMetrics = layout.expandedMetricIDs
        let expandOnEnable = layout.defaultExpandedOnEnableIDs
        let expandedProviders = layout.expandedProviderIDs
        let selections = DashboardUsageAccountSelection.storedSelections(defaults: defaults)
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        let persistedPlaced = persistence.loadPlaced()
        let persistedProviderOrder = persistence.loadProviderOrder()
        let persistedMetricOrder = persistence.loadMetricOrder()
        let persistedPins = persistence.loadPins()
        let persistedExpandedMetrics = persistence.loadExpandedMetrics()
        let persistedExpandOnEnable = persistence.loadExpandOnEnable()
        let persistedExpandedProviders = persistence.loadExpandedProviders()

        let presentation = AccountCardPresentationStore(defaults: defaults)
        XCTAssertTrue(presentation.reorder(
            dragged: work.id,
            target: company.id,
            family: "claude",
            profiles: profiles
        ))
        XCTAssertTrue(presentation.reorder(
            dragged: sub.id,
            target: personal.id,
            family: "codex",
            profiles: profiles
        ))
        let accountOrders = ["claude": [work.id, company.id], "codex": [sub.id, personal.id]]
        func presentedCardIDs() -> [String] {
            let families = ["claude", "codex"]
            let orderedIDs = AccountCardPresentationPlanner.orderedCardIDs(
                layout.displayGroups.map(\.provider.id),
                familyOrder: layout.customizeProviderRows.map(\.id),
                orderedProfileIDsByFamily: Dictionary(uniqueKeysWithValues: families.map {
                    ($0, presentation.orderedProfiles(profiles, family: $0).map(\.id))
                }),
                profileIDsByCardID: ["claude": company.id, cardID: work.id, "codex": personal.id, codexCardID: sub.id]
            )
            return AccountCardPresentationPlanner.presentedCardIDs(
                orderedCardIDs: orderedIDs,
                modesByFamily: Dictionary(uniqueKeysWithValues: families.map {
                    ($0, presentation.effectiveMode(for: $0, profiles: profiles, registryReadable: true))
                }),
                selectedCardIDsByFamily: DashboardUsageAccountSelection.storedSelections(defaults: defaults)
            )
        }

        XCTAssertEqual(presentedCardIDs(), [codexCardID, cardID])
        presentation.setMode(.separateCards)
        XCTAssertEqual(presentation.mode, .separateCards)
        XCTAssertEqual(presentedCardIDs(), [codexCardID, "codex", cardID, "claude"])
        presentation.setMode(.singleCard)
        XCTAssertEqual(presentation.mode, .singleCard)
        XCTAssertEqual(presentedCardIDs(), [codexCardID, cardID])
        for family in ["claude", "codex"] {
            XCTAssertEqual(presentation.orderedProfiles(profiles, family: family).map(\.id), accountOrders[family])
        }
        XCTAssertEqual(layout.providerOrder, providerOrder)
        XCTAssertEqual(layout.placed, placed)
        XCTAssertEqual(layout.metricOrderByProvider, metricOrder)
        XCTAssertEqual(layout.pinnedMetricIDs, pins)
        XCTAssertEqual(layout.expandedMetricIDs, expandedMetrics)
        XCTAssertEqual(layout.defaultExpandedOnEnableIDs, expandOnEnable)
        XCTAssertEqual(layout.expandedProviderIDs, expandedProviders)
        XCTAssertEqual(DashboardUsageAccountSelection.storedSelections(defaults: defaults), selections)
        XCTAssertEqual(persistence.loadPlaced(), persistedPlaced)
        XCTAssertEqual(persistence.loadProviderOrder(), persistedProviderOrder)
        XCTAssertEqual(persistence.loadMetricOrder(), persistedMetricOrder)
        XCTAssertEqual(persistence.loadPins(), persistedPins)
        XCTAssertEqual(persistence.loadExpandedMetrics(), persistedExpandedMetrics)
        XCTAssertEqual(persistence.loadExpandOnEnable(), persistedExpandOnEnable)
        XCTAssertEqual(persistence.loadExpandedProviders(), persistedExpandedProviders)
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

    private func makeStore(defaults: UserDefaults, includesCodexAccountCard: Bool = false) -> LayoutStore {
        LayoutStore(
            registry: .accountCards(includesCodexAccountCard: includesCodexAccountCard),
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
    static func accountCards(includesCodexAccountCard: Bool) -> WidgetRegistry {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let card = Provider(id: "claude@profile-work", displayName: "Claude — Work", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var providers = [claude, card, codex]
        if includesCodexAccountCard {
            providers.append(Provider(id: "codex@profile-sub", displayName: "Codex — Sub", icon: .providerMark("codex")))
        }
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
            providers: providers,
            descriptors: providers.flatMap(descriptors)
        )
    }
}
