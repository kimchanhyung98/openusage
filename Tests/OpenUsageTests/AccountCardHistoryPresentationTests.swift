import XCTest
@testable import OpenUsage

@MainActor
final class AccountCardHistoryPresentationTests: XCTestCase {
    func testSeparateSnapshotCardsOmitTrendTodayAndYesterdayButKeepAccountLimits() throws {
        let layout = makeLayout()
        let snapshots = layout.displayGroups.filter { ProviderAccountID.isAccountCard($0.id) }
        XCTAssertEqual(snapshots.count, 3)
        for group in snapshots {
            let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
            XCTAssertEqual(presented.alwaysShownWidgets.map(\.descriptorID), ["\(group.id).weekly"])
            let expandedIDs = group.id.hasPrefix("codex") ? ["\(group.id).rateLimitResets"] : []
            XCTAssertEqual(presented.expandedWidgets.map(\.descriptorID), expandedIDs)
        }
    }

    func testSharedHomeCardsKeepHistoryInSeparateMode() throws {
        let layout = makeLayout()
        for group in layout.displayGroups where !ProviderAccountID.isAccountCard(group.id) {
            let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
            XCTAssertEqual(presented.alwaysShownWidgets, group.alwaysShownWidgets)
            XCTAssertEqual(presented.expandedWidgets, group.expandedWidgets)
            XCTAssertTrue(presented.widgets.contains { $0.descriptorID == "\(group.id).trend" })
            XCTAssertTrue(presented.widgets.contains { $0.descriptorID == "\(group.id).today" })
            XCTAssertTrue(presented.widgets.contains { $0.descriptorID == "\(group.id).yesterday" })
        }
    }

    func testSingleCardKeepsTheSelectedSnapshotHistoryRows() throws {
        let layout = makeLayout()
        let selectedID = "codex@profile-company"
        let ids = AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: layout.displayGroups.map(\.id),
            modesByFamily: ["codex": .singleCard],
            selectedCardIDsByFamily: ["codex": selectedID]
        )
        XCTAssertTrue(ids.contains(selectedID))
        XCTAssertFalse(ids.contains("codex"))
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == selectedID })
        let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .singleCard))
        XCTAssertEqual(presented.alwaysShownWidgets, group.alwaysShownWidgets)
        XCTAssertEqual(presented.expandedWidgets, group.expandedWidgets)
    }

    func testSeparateHistoryDoesNotFollowDashboardSelection() throws {
        let layout = makeLayout()
        let selections = ["claude": "claude@profile-work", "codex": "codex@profile-company"]
        let modes: [String: AccountCardDisplayMode] = ["claude": .separateCards, "codex": .separateCards]
        let ids = AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: layout.displayGroups.map(\.id),
            modesByFamily: modes,
            selectedCardIDsByFamily: selections
        )
        let groups = layout.displayGroups.filter { ids.contains($0.id) }.compactMap {
            AccountCardPresentationPlanner.presentedGroup($0, mode: .separateCards)
        }
        XCTAssertEqual(groups.filter { $0.widgets.contains { $0.descriptorID.hasSuffix(".trend") } }.map(\.id),
                       ["claude", "codex"])
    }

    func testFilteringPromotesRemainingLimitsWithoutChangingSavedLayout() throws {
        let layout = makeLayout()
        layout.expandedMetricIDs = ["codex.weekly", "codex.rateLimitResets"]
        let placed = layout.placed
        let expandedIDs = layout.expandedMetricIDs
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == "codex@profile-company" })
        let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))

        XCTAssertEqual(presented.alwaysShownWidgets, group.expandedWidgets)
        XCTAssertFalse(presented.hasExpandedMetrics)
        XCTAssertEqual(layout.placed, placed)
        XCTAssertEqual(layout.expandedMetricIDs, expandedIDs)
        XCTAssertEqual(layout.displayGroups.first { $0.id == group.id }?.widgets, group.widgets)
    }

    func testHistoryOnlySnapshotDoesNotLeaveAnEmptyCard() throws {
        let layout = makeLayout()
        layout.setMetricEnabled("claude.weekly", false)
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == "claude@profile-work" })
        XCTAssertFalse(group.widgets.isEmpty)
        XCTAssertNil(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
    }

    func testPromotedLimitsCanBeReorderedWhileCollapsed() throws {
        let layout = makeLayout()
        layout.expandedMetricIDs = ["codex.weekly", "codex.rateLimitResets"]
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == "codex@profile-company" })
        let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
        let weekly = "\(group.id).weekly"
        let resets = "\(group.id).rateLimitResets"
        let target = try XCTUnwrap(reorderTarget(
            at: CGPoint(x: 20, y: 48),
            in: [weekly: CGRect(x: 0, y: 0, width: 100, height: 40),
                 resets: CGRect(x: 0, y: 40, width: 100, height: 40)],
            excluding: weekly,
            orderedIDs: presented.alwaysShownWidgets.map(\.descriptorID)
        ))
        XCTAssertEqual(target, resets)
        XCTAssertTrue(layout.reorderDashboardMetric(dragged: weekly, target: target, in: presented, dividerID: "divider"))
        let reordered = try XCTUnwrap(layout.displayGroups.first { $0.id == group.id })
        let next = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(reordered, mode: .separateCards))
        XCTAssertEqual(next.alwaysShownWidgets.map(\.descriptorID), [resets, weekly])
        XCTAssertEqual(layout.expandedMetricIDs, ["codex.weekly", "codex.rateLimitResets"])
    }

    func testReorderingFilteredRowsPreservesHiddenHistoryMembershipAndPins() throws {
        let layout = makeLayout()
        layout.setPinned(true, for: "codex.today")
        let pins = layout.pinnedMetricIDs
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == "codex@profile-company" })
        let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
        XCTAssertTrue(layout.setProviderExpanded(true, for: group.id))
        let divider = "divider"
        let dragged = "\(group.id).rateLimitResets"

        XCTAssertTrue(layout.reorderDashboardMetric(dragged: dragged, target: divider, in: presented, dividerID: divider))
        XCTAssertFalse(layout.isExpandedMetric(dragged))
        for suffix in ["trend", "today", "yesterday"] {
            XCTAssertTrue(layout.isExpandedMetric("codex.\(suffix)"))
            XCTAssertTrue(layout.isMetricEnabled("codex.\(suffix)"))
        }
        XCTAssertEqual(layout.pinnedMetricIDs, pins)
    }

    func testReorderingPromotedLimitsWithLinksExpandedPreservesSavedMembership() throws {
        let layout = makeLayout()
        layout.expandedMetricIDs = ["codex.weekly", "codex.rateLimitResets"]
        let originalExpanded = layout.expandedMetricIDs
        let cardID = "codex@profile-company"
        XCTAssertTrue(layout.setProviderExpanded(true, for: cardID))
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == cardID })
        let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
        XCTAssertFalse(presented.provider.visibleLinks.isEmpty)
        XCTAssertTrue(presented.expandedWidgets.isEmpty)
        let weekly = "\(cardID).weekly"
        let resets = "\(cardID).rateLimitResets"
        let divider = "\(cardID)::dashboard-expanded-divider"
        XCTAssertEqual(layout.dashboardMetricTargetIDs(in: presented, dividerID: divider), [weekly, resets, divider])
        XCTAssertTrue(layout.reorderDashboardMetric(dragged: weekly, target: resets, in: presented, dividerID: divider))

        XCTAssertEqual(layout.expandedMetricIDs, originalExpanded)
        let reordered = try XCTUnwrap(layout.displayGroups.first { $0.id == cardID })
        let final = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(reordered, mode: .separateCards))
        XCTAssertEqual(final.alwaysShownWidgets.map(\.descriptorID), [resets, weekly])

        XCTAssertTrue(layout.undo())
        XCTAssertEqual(layout.expandedMetricIDs, originalExpanded)
        let restored = try XCTUnwrap(layout.displayGroups.first { $0.id == cardID })
        let undo = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(restored, mode: .separateCards))
        XCTAssertEqual(undo.alwaysShownWidgets.map(\.descriptorID), [weekly, resets])
    }

    func testReorderingPromotedSharedHomeLimitsPreservesSavedMembership() throws {
        let layout = makeLayout()
        for suffix in ["trend", "today", "yesterday"] {
            layout.setMetricEnabled("codex.\(suffix)", false)
        }
        layout.expandedMetricIDs = ["codex.weekly", "codex.rateLimitResets"]
        let originalExpanded = layout.expandedMetricIDs
        XCTAssertTrue(layout.setProviderExpanded(true, for: "codex"))
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == "codex" })
        XCTAssertTrue(group.expandedWidgets.isEmpty)

        XCTAssertTrue(layout.reorderDashboardMetric(
            dragged: "codex.weekly", target: "codex.rateLimitResets", in: group, dividerID: "divider"
        ))

        XCTAssertEqual(layout.expandedMetricIDs, originalExpanded)
    }

    func testDashboardReorderRejectsHiddenAndOtherAccountTargets() throws {
        let layout = makeLayout()
        let cardID = "codex@profile-company"
        let group = try XCTUnwrap(layout.displayGroups.first { $0.id == cardID })
        let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
        let originalOrder = layout.metricOrderByProvider
        let originalExpanded = layout.expandedMetricIDs
        let divider = "\(cardID)::dashboard-expanded-divider"

        for target in ["\(cardID).trend", "\(cardID).rateLimitResets", "codex.weekly", divider] {
            XCTAssertFalse(layout.reorderDashboardMetric(
                dragged: "\(cardID).weekly", target: target, in: presented, dividerID: divider
            ), target)
        }

        XCTAssertEqual(layout.metricOrderByProvider, originalOrder)
        XCTAssertEqual(layout.expandedMetricIDs, originalExpanded)
    }

    func testLast30DaysIsNotChangedByTheThreeRowFilter() throws {
        let layout = makeLayout()
        for (family, cardID) in [("claude", "claude@profile-work"), ("codex", "codex@profile-company")] {
            layout.setMetricEnabled("\(family).last30", true)
            let group = try XCTUnwrap(layout.displayGroups.first { $0.id == cardID })
            let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
            XCTAssertTrue(presented.widgets.contains { $0.descriptorID == "\(group.id).last30" })
        }
    }

    func testOtherProviderHistoryIsUnchanged() throws {
        for id in ["cursor", "cursor@remote"] {
            let provider = Provider(id: id, displayName: "Cursor", icon: .providerMark("cursor"))
            let group = ProviderGroup(
                provider: provider,
                alwaysShownWidgets: [PlacedWidget(descriptorID: "\(id).today")],
                expandedWidgets: [PlacedWidget(descriptorID: "\(id).trend")]
            )
            let presented = try XCTUnwrap(AccountCardPresentationPlanner.presentedGroup(group, mode: .separateCards))
            XCTAssertEqual(presented.widgets, group.widgets)
        }
    }

    private func makeLayout() -> LayoutStore {
        let suite = "OpenUsageTests.AccountCardHistoryPresentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let providers = ["claude", "claude@profile-work", "codex", "codex@profile-company", "codex@profile-default"]
            .map { id in
                ProviderAccountID.family(of: id) == "claude"
                    ? ClaudeProvider.makeProvider(id: id)
                    : CodexProvider.makeProvider(id: id)
            }
        let descriptors = providers.flatMap { provider in
            ProviderAccountID.family(of: provider.id) == "claude"
                ? ClaudeProvider(provider: provider).widgetDescriptors
                : CodexProvider(provider: provider).widgetDescriptors
        }
        let metricIDs = ["claude", "codex"].flatMap { family in
            ["weekly", "trend", "rateLimitResets", "today", "yesterday"].map { "\(family).\($0)" }
        }
        return LayoutStore(
            registry: WidgetRegistry(providers: providers, descriptors: descriptors),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: metricIDs,
            migrationBaselineMetricIDs: metricIDs,
            defaultPinnedMetricIDs: [],
            defaultExpandedMetricIDs: metricIDs.filter { !$0.hasSuffix(".weekly") }
        )
    }
}
