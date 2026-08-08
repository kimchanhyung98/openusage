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
        _ = try profiles.add(family: "claude", label: "default", identityKey: "acct-1")
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
        let personal = try profiles.add(family: "claude", label: "default", identityKey: "acct-1")
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

    func testAmbientClaudeCardMapsToTheProfileProvingTheSameAccount() throws {
        let profiles = AccountProfilesStore(defaults: makeScratchDefaults())
        _ = try profiles.add(family: "claude", label: "default", identityKey: "acct-1")
        let work = try profiles.add(family: "claude", label: "Work", identityKey: "acct-2")
        let card = ClaudeAccountCard(
            id: "claude@ab12cd34",
            displayName: "Claude — Work",
            configDirPath: "/Users/dev/.claude-work",
            keychainLiteral: "/Users/dev/.claude-work"
        )
        let assembly = ProviderAccountAssembly(
            identityKeysByCard: ["claude": "acct-1", card.id: "acct-2"],
            claudeCards: [card]
        )

        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)

        XCTAssertEqual(mapping[card.id], work.id)
    }
}
