import XCTest
@testable import OpenUsage

@MainActor
final class AccountCardMappingTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.AccountCardMapping.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testBareFamilyCardMapsToTheSelectedProfileWhenTheObservedIdentityMatches() throws {
        let profiles = AccountProfilesStore(defaults: makeScratchDefaults())
        _ = try profiles.add(family: "claude", label: "Account 1", identityKey: "acct-1")
        let work = try profiles.add(family: "claude", label: "Work", identityKey: "acct-2")
        profiles.setPreferred(family: "claude", profileID: work.id)
        let assembly = ProviderAccountAssembly(identityKeysByCard: ["claude": "acct-2"])

        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)

        XCTAssertEqual(mapping["claude"], work.id)
    }

    func testBareFamilyCardMapsToTheSelectedProfileWhenNoIdentityWasObserved() throws {
        let profiles = AccountProfilesStore(defaults: makeScratchDefaults())
        let work = try profiles.add(family: "codex", label: "Work", identityKey: "codex-2")
        profiles.setPreferred(family: "codex", profileID: work.id)
        let assembly = ProviderAccountAssembly(identityKeysByCard: [:])

        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)

        XCTAssertEqual(
            mapping["codex"], work.id,
            "an unresolved launch keeps the managed selection attached to the bare card"
        )
    }

    func testBareFamilyCardIsNotClaimedWhenAnotherAccountHoldsTheSharedHome() throws {
        let profiles = AccountProfilesStore(defaults: makeScratchDefaults())
        let work = try profiles.add(family: "claude", label: "Work", identityKey: "acct-2")
        profiles.setPreferred(family: "claude", profileID: work.id)
        // OpenUsage 외부에서 shared home이 다른 account로 로그인된 상태
        let assembly = ProviderAccountAssembly(identityKeysByCard: ["claude": "acct-9"])

        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)

        XCTAssertNil(
            mapping["claude"],
            "the bare card shows the outside login, so the selected profile must not claim its label"
        )
    }

    func testSnapshotCardKeepsItsExplicitProfileMapping() throws {
        let profiles = AccountProfilesStore(defaults: makeScratchDefaults())
        let personal = try profiles.add(family: "claude", label: "Account 1", identityKey: "acct-1")
        let work = try profiles.add(family: "claude", label: "Work", identityKey: "acct-2")
        profiles.setPreferred(family: "claude", profileID: work.id)
        let cardID = AccountUsageCardPlanner.cardID(family: "claude", profileID: personal.id)
        let assembly = ProviderAccountAssembly(
            identityKeysByCard: [cardID: "acct-1"],
            profileIDsByCard: [cardID: personal.id]
        )

        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)

        XCTAssertEqual(mapping[cardID], personal.id)
    }

    func testAnUnknownCardIsNotClaimedByARegisteredProfile() throws {
        let profiles = AccountProfilesStore(defaults: makeScratchDefaults())
        _ = try profiles.add(family: "claude", label: "alpha", identityKey: "acct-1")
        _ = try profiles.add(family: "claude", label: "beta", identityKey: "acct-2")
        let assembly = ProviderAccountAssembly(
            identityKeysByCard: ["claude": "acct-1", "claude@ab12cd34": "acct-2"]
        )

        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)

        XCTAssertNil(mapping["claude@ab12cd34"])
    }

    func testRegisteredCodexNamesStayTheOnlyCardsAcrossSharedHomeIdentityChanges() throws {
        let store = AccountProfilesStore(defaults: makeScratchDefaults())
        let names = ["Account 1", "Account 2", "Account 3"]
        let profiles = try names.enumerated().map { index, name in
            try store.add(family: "codex", label: name, identityKey: "identity-\(index + 1)")
        }
        store.setPreferred(family: "codex", profileID: profiles[0].id)

        for sharedIdentity in [profiles[0].identityKey, "identity-unregistered"] {
            let snapshots = AccountUsageCardPlanner.snapshotCards(
                profiles: profiles,
                preferredProfileIDs: ["codex": profiles[0].id],
                availableSnapshotProfileIDs: Set(profiles.map(\.id)),
                sharedHomeIdentityKeys: ["codex": sharedIdentity]
            )
            let assembly = ProviderAccountAssembly(
                identityKeysByCard: ["codex": sharedIdentity],
                snapshotCards: snapshots,
                profileIDsByCard: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0.profileID) })
            )
            let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: store)
            let ordered = AccountCardPresentationPlanner.orderedCardIDs(
                ["codex"] + snapshots.map(\.id),
                familyOrder: ["codex"],
                orderedProfileIDsByFamily: ["codex": profiles.map(\.id)],
                profileIDsByCardID: mapping
            )
            let presented = AccountCardPresentationPlanner.presentedCardIDs(
                orderedCardIDs: ordered,
                modesByFamily: ["codex": .separateCards],
                selectedCardIDsByFamily: ["codex": "codex"]
            )
            let titles = try presented.map { cardID in
                let profileID = try XCTUnwrap(mapping[cardID])
                let profile = try XCTUnwrap(store.profile(id: profileID))
                return AccountCardPresentationPlanner.cardTitle(
                    providerID: cardID, fallback: "Codex", mode: .separateCards, accountName: profile.label
                )
            }

            XCTAssertEqual(titles, names.map { "Codex: \($0)" })
            XCTAssertEqual(store.preferredProfileID(family: "codex"), profiles[0].id)
            XCTAssertEqual(store.profiles(family: "codex").map(\.identityKey), profiles.map(\.identityKey))
        }
    }
}
