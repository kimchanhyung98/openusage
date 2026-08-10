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

    func testASingleCardStaysVisible() {
        let cards = ["claude", "codex"]

        XCTAssertEqual(
            DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: cards,
                familyCardIDs: ["claude"],
                selectedCardID: "claude"
            ),
            cards
        )
    }

    func testEveryAccountOfAProviderCollapsesIntoTheSelectedCard() {
        let cards = ["claude", "claude@ambient-work", "claude@profile-personal", "codex"]

        XCTAssertEqual(
            DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: cards,
                familyCardIDs: ["claude", "claude@ambient-work", "claude@profile-personal"],
                selectedCardID: "claude@ambient-work"
            ),
            ["claude@ambient-work", "codex"],
            "a discovered config-dir login is an account of the same card, not a second card"
        )
    }

    func testARegisteredAccountIsListedByItsAccountName() {
        XCTAssertEqual(
            DashboardUsageAccountSelection.optionTitle(
                cardID: "claude@profile-personal",
                profileLabel: "personal",
                accountName: "Claude — Personal Org"
            ),
            "personal"
        )
    }

    func testADiscoveredAccountDropsTheProviderPrefix() {
        XCTAssertEqual(
            DashboardUsageAccountSelection.optionTitle(
                cardID: "claude@ab12cd34",
                profileLabel: nil,
                accountName: "Claude — Work Org"
            ),
            "Work Org"
        )
    }

    func testTheSharedHomeAccountIsListedAsDefault() {
        XCTAssertEqual(
            DashboardUsageAccountSelection.optionTitle(
                cardID: "claude",
                profileLabel: nil,
                accountName: "Claude"
            ),
            "Default"
        )
    }

    func testADiscoveredAccountWithoutANameFallsBackToItsCardID() {
        XCTAssertEqual(
            DashboardUsageAccountSelection.optionTitle(
                cardID: "claude@ab12cd34",
                profileLabel: nil,
                accountName: nil
            ),
            "claude@ab12cd34"
        )
    }

    func testAnUnknownSelectionLeavesEveryCardVisible() {
        let cards = ["claude", "claude@ambient-work"]

        XCTAssertEqual(
            DashboardUsageAccountSelection.visibleCardIDs(
                orderedCardIDs: cards,
                familyCardIDs: Set(cards),
                selectedCardID: "claude@gone"
            ),
            cards
        )
    }
}
