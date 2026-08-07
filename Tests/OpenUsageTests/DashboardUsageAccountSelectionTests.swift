import XCTest
@testable import OpenUsage

final class DashboardUsageAccountSelectionTests: XCTestCase {
    func testEachAccountFamilyKeepsItsOwnDashboardSelection() {
        let suiteName = "OpenUsageTests.DashboardUsageAccountSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DashboardUsageAccountSelection.select("claude@alpha", for: "claude", defaults: defaults)
        DashboardUsageAccountSelection.select("codex@work", for: "codex", defaults: defaults)

        XCTAssertEqual(DashboardUsageAccountSelection.selectedID(for: "claude", defaults: defaults), "claude@alpha")
        XCTAssertEqual(DashboardUsageAccountSelection.selectedID(for: "codex", defaults: defaults), "codex@work")
    }

    func testUnknownFamilyDoesNotStoreASelection() {
        let suiteName = "OpenUsageTests.DashboardUsageAccountSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DashboardUsageAccountSelection.select("unknown@account", for: "other", defaults: defaults)

        XCTAssertEqual(DashboardUsageAccountSelection.selectedID(for: "other", defaults: defaults), "")
    }

    func testAccountSwitchReplacesAStaleAmbientCardWithTheSharedRuntime() {
        let suiteName = "OpenUsageTests.DashboardUsageAccountSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DashboardUsageAccountSelection.select("claude@b81c9bc9", for: "claude", defaults: defaults)

        let selectedID = DashboardUsageAccountSelection.selectAfterAccountSwitch(
            family: "claude",
            availableCardIDs: ["claude", "claude@b81c9bc9"],
            defaults: defaults
        )

        XCTAssertEqual(selectedID, "claude")
        XCTAssertEqual(DashboardUsageAccountSelection.selectedID(for: "claude", defaults: defaults), "claude")
    }

    func testNoManagedCardsLeavesAllDiscoveredCardsVisible() {
        let cards = ["claude", "claude@ambient-work"]

        XCTAssertEqual(
            DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: cards,
                managedCardIDs: [],
                selectedManagedCardID: nil
            ),
            cards
        )
    }

    func testManagedSelectionHidesOnlyOtherManagedCards() {
        let cards = ["claude", "claude@ambient-work", "claude@profile-personal"]

        XCTAssertEqual(
            DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: cards,
                managedCardIDs: ["claude", "claude@profile-personal"],
                selectedManagedCardID: "claude"
            ),
            ["claude", "claude@ambient-work"],
            "an unmanaged discovered card must retain its existing dashboard section"
        )
    }

    func testOneManagedCardDoesNotCollapseDiscoveredCards() {
        let cards = ["claude", "claude@ambient-work"]

        XCTAssertEqual(
            DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: cards,
                managedCardIDs: ["claude"],
                selectedManagedCardID: "claude"
            ),
            cards
        )
    }
}
