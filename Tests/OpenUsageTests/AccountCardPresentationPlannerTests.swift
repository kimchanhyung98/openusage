import XCTest
@testable import OpenUsage

final class AccountCardPresentationPlannerTests: XCTestCase {
    func testOnlyConflictingUnmanagedNamesReceiveASharedHomeSuffix() {
        XCTAssertEqual(
            AccountCardPresentationPlanner.unmanagedAccountName("Default", reservedNames: ["Work"]),
            "Default"
        )
        XCTAssertEqual(
            AccountCardPresentationPlanner.unmanagedAccountName("Default", reservedNames: ["default"]),
            "Default (Shared Home)"
        )
        XCTAssertEqual(
            AccountCardPresentationPlanner.unmanagedAccountName(
                "Default", reservedNames: ["Default", "Default (Shared Home)", "Default (Shared Home) 2"]
            ),
            "Default (Shared Home) 3"
        )
    }

    func testCanonicalFamilyOrderWinsOverFirstRawCardOccurrence() {
        let cards = ["claude@profile-company", "cursor", "codex", "claude", "codex@profile-sub"]

        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            cards,
            familyOrder: ["codex", "claude", "cursor"],
            orderedProfileIDsByFamily: ["claude": ["personal", "company"], "codex": ["sub", "main"]],
            profileIDsByCardID: [
                "claude": "personal", "claude@profile-company": "company",
                "codex": "main", "codex@profile-sub": "sub",
            ]
        ), ["codex@profile-sub", "codex", "claude", "claude@profile-company", "cursor"])
    }

    func testManagedCardsPrecedeUnmanagedCardsKeepingTheirRelativeOrder() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["claude@external-two", "claude@profile-b", "claude@external-one", "claude"],
            familyOrder: ["claude"],
            orderedProfileIDsByFamily: ["claude": ["a", "b"]],
            profileIDsByCardID: ["claude": "a", "claude@profile-b": "b"]
        ), ["claude", "claude@profile-b", "claude@external-two", "claude@external-one"])
    }

    func testMissingRuntimeHasNoPlaceholderAndRetainsItsRankWhenItReturns() {
        let profiles = ["claude": ["b", "a", "c"]]
        let mapping = ["claude": "a", "claude@profile-b": "b", "claude@profile-c": "c"]

        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["claude", "claude@profile-c"], familyOrder: ["claude"],
            orderedProfileIDsByFamily: profiles, profileIDsByCardID: mapping
        ), ["claude", "claude@profile-c"])
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["claude", "claude@profile-c", "claude@profile-b"], familyOrder: ["claude"],
            orderedProfileIDsByFamily: profiles, profileIDsByCardID: mapping
        ), ["claude@profile-b", "claude", "claude@profile-c"])
    }

    func testRuntimeRebindingKeepsProfileOrderInsteadOfBareIDPosition() {
        let before = AccountCardPresentationPlanner.orderedCardIDs(
            ["claude", "claude@profile-b"], familyOrder: ["claude"],
            orderedProfileIDsByFamily: ["claude": ["b", "a"]],
            profileIDsByCardID: ["claude": "a", "claude@profile-b": "b"]
        )
        let after = AccountCardPresentationPlanner.orderedCardIDs(
            ["claude", "claude@profile-a"], familyOrder: ["claude"],
            orderedProfileIDsByFamily: ["claude": ["b", "a"]],
            profileIDsByCardID: ["claude": "b", "claude@profile-a": "a"]
        )

        XCTAssertEqual(before, ["claude@profile-b", "claude"])
        XCTAssertEqual(after, ["claude", "claude@profile-a"])
    }

    func testUnlistedProvidersAppendAndNonAccountIDsRemainDistinct() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["cursor@remote", "claude@profile-a", "cursor", "grok", "claude"],
            familyOrder: ["grok", "missing", "grok", "claude", "claude@profile-a"],
            orderedProfileIDsByFamily: [:], profileIDsByCardID: [:]
        ), ["grok", "claude@profile-a", "claude", "cursor@remote", "cursor"])
    }

    func testSingleCardSelectsOneRuntimePerFamilyWithoutChangingOtherProviders() {
        let cards = ["codex@profile-sub", "codex", "claude", "claude@profile-work", "cursor"]

        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["claude": .singleCard, "codex": .singleCard],
            selectedCardIDsByFamily: ["claude": "claude@profile-work", "codex": "codex"]
        ), ["codex", "claude@profile-work", "cursor"])
    }

    func testEffectiveDisplayModesKeepSeparateCardsAndSingleCardFallback() {
        let cards = ["codex@profile-sub", "codex", "claude", "claude@profile-work", "cursor"]

        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["claude": .singleCard, "codex": .separateCards],
            selectedCardIDsByFamily: ["claude": "claude@profile-work", "codex": "codex"]
        ), ["codex@profile-sub", "codex", "claude@profile-work", "cursor"])
        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["claude": .separateCards, "codex": .separateCards],
            selectedCardIDsByFamily: [:]
        ), cards)
    }

    func testDefaultSingleFallbackPrefersBareRuntimeThenFirstAvailableRuntime() {
        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: ["claude@profile-first", "claude", "codex@profile-second", "codex@profile-first"],
            modesByFamily: [:],
            selectedCardIDsByFamily: ["claude": "removed", "codex": "claude"]
        ), ["claude", "codex@profile-second"])
    }

    func testSeparateCardsIgnoreValidStaleAndCrossFamilySelections() {
        let cards = ["claude", "claude@profile-work", "codex", "codex@profile-sub", "cursor"]
        for selection in ["", "claude", "claude@profile-work", "removed", "codex@profile-sub"] {
            XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
                orderedCardIDs: cards,
                modesByFamily: ["claude": .separateCards, "codex": .separateCards],
                selectedCardIDsByFamily: ["claude": selection, "codex": selection]
            ), cards)
        }
    }

    func testEmptyInputsAndUnsupportedProvidersRemainUnaffected() {
        XCTAssertTrue(AccountCardPresentationPlanner.orderedCardIDs(
            [], familyOrder: ["claude"], orderedProfileIDsByFamily: [:], profileIDsByCardID: [:]
        ).isEmpty)
        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: ["cursor@remote", "cursor"],
            modesByFamily: ["cursor": .singleCard],
            selectedCardIDsByFamily: ["cursor": "cursor"]
        ), ["cursor@remote", "cursor"])
    }

    func testTitlesUseExactManagedNameOnlyInSeparateMode() {
        XCTAssertEqual(title("codex@profile-sub", mode: .separateCards, name: "sub"), "Codex: sub")
        XCTAssertEqual(title("claude", mode: .separateCards, name: "company"), "Claude: company")
        XCTAssertEqual(title("claude@profile-work", mode: .separateCards, name: "회사: 개발 · 팀"), "Claude: 회사: 개발 · 팀")
        XCTAssertEqual(title("codex", mode: .singleCard, name: "sub"), "Codex")
        XCTAssertEqual(title("claude@profile-work", mode: .singleCard, name: "company"), "Claude")
    }

    func testDefaultAccountFallbackAndNonAccountProviderTitlesStayIntact() {
        XCTAssertEqual(title("claude", mode: .separateCards, name: "Default"), "Claude: Default")
        XCTAssertEqual(title("codex@unmanaged", mode: .separateCards, name: "codex@unmanaged"), "Codex: codex@unmanaged")
        XCTAssertEqual(title("cursor", mode: .separateCards, name: "unused"), "Existing Title")
    }

    private func title(_ providerID: String, mode: AccountCardDisplayMode, name: String) -> String {
        AccountCardPresentationPlanner.cardTitle(
            providerID: providerID, fallback: "Existing Title", mode: mode, accountName: name
        )
    }
}
