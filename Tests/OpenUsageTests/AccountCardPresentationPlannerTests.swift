import XCTest
@testable import OpenUsage

final class AccountCardPresentationPlannerTests: XCTestCase {
    func testRegisteredCodexAccountsExcludeTheAdditionalSharedHomeCard() {
        let registeredCards = ["account-1", "account-2", "account-3"].map { "codex@profile-\($0)" }
        let cards = AccountCardPresentationPlanner.orderedCardIDs(
            ["codex"] + registeredCards,
            familyOrder: ["codex"],
            orderedProfileIDsByFamily: ["codex": ["account-1", "account-2", "account-3"]],
            profileIDsByCardID: Dictionary(uniqueKeysWithValues: zip(registeredCards, ["account-1", "account-2", "account-3"]))
        )

        XCTAssertEqual(cards, registeredCards)
        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["codex": .separateCards],
            selectedCardIDsByFamily: ["codex": "codex"]
        ), registeredCards)
        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["codex": .singleCard],
            selectedCardIDsByFamily: ["codex": "codex"]
        ), [registeredCards[0]])
    }

    func testMissingRegisteredCredentialsDoNotExposeAnUnregisteredSharedHome() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["codex", "cursor"],
            familyOrder: ["codex", "cursor"],
            orderedProfileIDsByFamily: ["codex": ["account-1", "account-2", "account-3"]],
            profileIDsByCardID: [:]
        ), ["cursor"])
    }

    func testAProviderWithoutRegisteredAccountsKeepsItsDefaultCard() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["claude", "codex", "cursor"],
            familyOrder: ["claude", "codex", "cursor"],
            orderedProfileIDsByFamily: ["claude": [], "codex": []],
            profileIDsByCardID: [:]
        ), ["claude", "codex", "cursor"])
    }

    func testSharedHomeMappedToARegisteredAccountRemainsVisibleUnderItsName() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["codex@profile-account-3", "codex", "codex@profile-account-2"],
            familyOrder: ["codex"],
            orderedProfileIDsByFamily: ["codex": ["account-1", "account-2", "account-3"]],
            profileIDsByCardID: ["codex": "account-1", "codex@profile-account-2": "account-2", "codex@profile-account-3": "account-3"]
        ), ["codex", "codex@profile-account-2", "codex@profile-account-3"])
        XCTAssertEqual(title("codex", mode: .separateCards, name: "Account 1"), "Codex: Account 1")
    }

    func testStaleProfileMappingDoesNotExposeRemovedAccountCards() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["claude", "claude@profile-work", "claude@profile-removed"],
            familyOrder: ["claude"],
            orderedProfileIDsByFamily: ["claude": ["work"]],
            profileIDsByCardID: ["claude": "removed", "claude@profile-work": "work", "claude@profile-removed": "removed"]
        ), ["claude@profile-work"])
    }

    func testCanonicalFamilyOrderWinsOverFirstRawCardOccurrence() {
        let cards = ["claude@profile-account-3", "cursor", "codex", "claude", "codex@profile-account-2"]

        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            cards,
            familyOrder: ["codex", "claude", "cursor"],
            orderedProfileIDsByFamily: ["claude": ["personal", "account-3"], "codex": ["account-2", "main"]],
            profileIDsByCardID: [
                "claude": "personal", "claude@profile-account-3": "account-3",
                "codex": "main", "codex@profile-account-2": "account-2",
            ]
        ), ["codex@profile-account-2", "codex", "claude", "claude@profile-account-3", "cursor"])
    }

    func testRegisteredClaudeAccountsExcludeUnmanagedCards() {
        XCTAssertEqual(AccountCardPresentationPlanner.orderedCardIDs(
            ["claude@external-two", "claude@profile-b", "claude@external-one", "claude"],
            familyOrder: ["claude"],
            orderedProfileIDsByFamily: ["claude": ["a", "b"]],
            profileIDsByCardID: ["claude": "a", "claude@profile-b": "b"]
        ), ["claude", "claude@profile-b"])
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
        let cards = ["codex@profile-account-2", "codex", "claude", "claude@profile-work", "cursor"]

        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["claude": .singleCard, "codex": .singleCard],
            selectedCardIDsByFamily: ["claude": "claude@profile-work", "codex": "codex"]
        ), ["codex", "claude@profile-work", "cursor"])
    }

    func testEffectiveDisplayModesKeepSeparateCardsAndSingleCardFallback() {
        let cards = ["codex@profile-account-2", "codex", "claude", "claude@profile-work", "cursor"]

        XCTAssertEqual(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cards,
            modesByFamily: ["claude": .singleCard, "codex": .separateCards],
            selectedCardIDsByFamily: ["claude": "claude@profile-work", "codex": "codex"]
        ), ["codex@profile-account-2", "codex", "claude@profile-work", "cursor"])
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
        let cards = ["claude", "claude@profile-work", "codex", "codex@profile-account-2", "cursor"]
        for selection in ["", "claude", "claude@profile-work", "removed", "codex@profile-account-2"] {
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
        XCTAssertEqual(title("codex@profile-account-2", mode: .separateCards, name: "Account 2"), "Codex: Account 2")
        XCTAssertEqual(title("claude", mode: .separateCards, name: "Account 3"), "Claude: Account 3")
        XCTAssertEqual(title("claude@profile-work", mode: .separateCards, name: "회사: 개발 · 팀"), "Claude: 회사: 개발 · 팀")
        XCTAssertEqual(title("codex", mode: .singleCard, name: "Account 2"), "Codex")
        XCTAssertEqual(title("claude@profile-work", mode: .singleCard, name: "Account 3"), "Claude")
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
