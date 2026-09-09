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
            profileID: "profile-beta",
            availableCardIDs: ["claude", "claude@b81c9bc9"],
            defaults: defaults
        )

        XCTAssertEqual(selectedID, "claude")
        XCTAssertEqual(
            DashboardUsageAccountSelection.selectedID(for: "claude", defaults: defaults),
            AccountUsageCardPlanner.cardID(family: "claude", profileID: "profile-beta")
        )
    }

    func testSelectingALiveAccountKeepsThatProfileWhenItBecomesASnapshot() {
        let suiteName = "OpenUsageTests.DashboardUsageAccountSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for family in AccountProfilesStore.supportedFamilies {
            DashboardUsageAccountSelection.select(family, for: family, profileID: "account-2", defaults: defaults)
            let snapshot = AccountUsageCardPlanner.cardID(family: family, profileID: "account-2")

            XCTAssertEqual(
                DashboardUsageAccountSelection.visibleCardID(
                    for: family,
                    among: [family, snapshot],
                    stored: DashboardUsageAccountSelection.selectedID(for: family, defaults: defaults),
                    preferredCardID: family,
                    profileIDsByCardID: [family: "account-1", snapshot: "account-2"]
                ),
                snapshot,
                "the bare runtime now belongs to another account, but the selected profile remains available"
            )
        }
    }

    func testRegisteredSelectionUsesTheSameIDForLiveAndSnapshotCards() {
        for family in AccountProfilesStore.supportedFamilies {
            let snapshot = AccountUsageCardPlanner.cardID(family: family, profileID: "account-2")
            for cardID in [family, snapshot] {
                XCTAssertEqual(
                    DashboardUsageAccountSelection.selectionID(
                        for: cardID, family: family, profileID: "account-2"
                    ),
                    snapshot
                )
            }
        }
    }

    func testSelectionsWithoutARegisteredProfileKeepTheirExistingIDs() {
        for cardID in ["codex", "codex@ambient", "codex@profile-account-2"] {
            XCTAssertEqual(
                DashboardUsageAccountSelection.selectionID(for: cardID, family: "codex", profileID: nil),
                cardID
            )
        }
    }

    func testLiveAccountSelectionSurvivesReloadingPreferences() {
        let suiteName = "OpenUsageTests.DashboardUsageAccountSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        DashboardUsageAccountSelection.select("codex", for: "codex", profileID: "account-2", defaults: defaults)

        let reloaded = UserDefaults(suiteName: suiteName)!

        XCTAssertEqual(
            DashboardUsageAccountSelection.storedSelections(defaults: reloaded)["codex"],
            AccountUsageCardPlanner.cardID(family: "codex", profileID: "account-2")
        )
    }

    func testAccountSwitchWithoutASharedRuntimeLeavesTheSelectionUntouched() {
        let suiteName = "OpenUsageTests.DashboardUsageAccountSelection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let previous = AccountUsageCardPlanner.cardID(family: "codex", profileID: "account-1")
        DashboardUsageAccountSelection.select(previous, for: "codex", defaults: defaults)

        XCTAssertNil(DashboardUsageAccountSelection.selectAfterAccountSwitch(
            family: "codex",
            profileID: "account-2",
            availableCardIDs: [previous],
            defaults: defaults
        ))
        XCTAssertEqual(DashboardUsageAccountSelection.selectedID(for: "codex", defaults: defaults), previous)
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

    func testSavedSnapshotSelectionFollowsItsLiveCardBeforeThePreferredAccount() {
        for family in AccountProfilesStore.supportedFamilies {
            let preferred = AccountUsageCardPlanner.cardID(family: family, profileID: "profile-1")
            let stored = AccountUsageCardPlanner.cardID(family: family, profileID: "profile-2")

            XCTAssertEqual(
                DashboardUsageAccountSelection.visibleCardID(
                    for: family,
                    among: [preferred, family],
                    stored: stored,
                    preferredCardID: preferred,
                    profileIDsByCardID: [preferred: "profile-1", family: "profile-2"]
                ),
                family,
                "the selected named account remains available even after its snapshot is replaced"
            )
        }
    }

    func testAnAvailableStoredSelectionWinsOverThePreferredAndLiveCards() {
        let snapshot = AccountUsageCardPlanner.cardID(family: "codex", profileID: "profile-2")

        for stored in [snapshot, "codex"] {
            XCTAssertEqual(
                DashboardUsageAccountSelection.visibleCardID(
                    for: "codex",
                    among: ["codex", snapshot],
                    stored: stored,
                    preferredCardID: "codex",
                    profileIDsByCardID: ["codex": "profile-1", snapshot: "profile-2"]
                ),
                stored
            )
        }
    }

    func testUnrelatedStoredSelectionsKeepThePreferredAccountFallback() {
        let preferred = AccountUsageCardPlanner.cardID(family: "codex", profileID: "profile-1")
        let missing = AccountUsageCardPlanner.cardID(family: "codex", profileID: "profile-3")
        let otherFamily = AccountUsageCardPlanner.cardID(family: "claude", profileID: "profile-2")

        for stored in ["", missing, otherFamily, "codex@ambient"] {
            XCTAssertEqual(
                DashboardUsageAccountSelection.visibleCardID(
                    for: "codex",
                    among: ["codex", preferred],
                    stored: stored,
                    preferredCardID: preferred,
                    profileIDsByCardID: [preferred: "profile-1", "codex": "profile-2"]
                ),
                preferred
            )
        }
    }

    func testUnmappedCardsKeepTheSharedHomeThenFirstCardFallback() {
        for cards in [["codex@ambient", "codex"], ["codex@ambient"]] {
            XCTAssertEqual(
                DashboardUsageAccountSelection.visibleCardID(
                    for: "codex",
                    among: cards,
                    stored: AccountUsageCardPlanner.cardID(family: "codex", profileID: "profile-2"),
                    preferredCardID: nil,
                    profileIDsByCardID: [:]
                ),
                cards.contains("codex") ? "codex" : cards.first
            )
        }
    }

    func testNoAvailableCardsProducesNoVisibleSelection() {
        XCTAssertNil(
            DashboardUsageAccountSelection.visibleCardID(
                for: "codex",
                among: [],
                stored: "codex",
                preferredCardID: nil,
                profileIDsByCardID: ["codex": "profile-1"]
            )
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
