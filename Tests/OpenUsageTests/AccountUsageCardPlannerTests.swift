import XCTest
@testable import OpenUsage

final class AccountUsageCardPlannerTests: XCTestCase {
    func testInactiveProfileWithSavedCredentialsGetsAUsageCard() {
        let personal = profile(id: "personal", family: "claude")
        let work = profile(id: "work", family: "claude")

        XCTAssertEqual(
            AccountUsageCardPlanner.snapshotCards(
                profiles: [personal, work],
                preferredProfileIDs: ["claude": work.id],
                availableSnapshotProfileIDs: [personal.id]
            ),
            [
                AccountUsageSnapshotCard(
                    id: "claude@profile-personal",
                    profileID: personal.id,
                    family: "claude"
                )
            ]
        )
    }

    func testPreferredProfileDoesNotGetADuplicateSnapshotCard() {
        let personal = profile(id: "personal", family: "codex")

        XCTAssertTrue(AccountUsageCardPlanner.snapshotCards(
            profiles: [personal],
            preferredProfileIDs: ["codex": personal.id],
            availableSnapshotProfileIDs: [personal.id]
        ).isEmpty)
    }

    func testSelectedProfileGetsASnapshotCardWhenTheSharedHomeServesAnotherAccount() {
        let personal = profile(id: "personal", family: "claude")

        XCTAssertEqual(
            AccountUsageCardPlanner.snapshotCards(
                profiles: [personal],
                preferredProfileIDs: ["claude": personal.id],
                availableSnapshotProfileIDs: [personal.id],
                sharedHomeIdentityKeys: ["claude": "identity-someone-else"]
            ),
            [
                AccountUsageSnapshotCard(
                    id: "claude@profile-personal",
                    profileID: personal.id,
                    family: "claude"
                )
            ],
            "without a card the selected profile would vanish while the home shows another account"
        )
    }

    func testSelectedProfileStaysCardFreeWhileTheSharedHomeServesIt() {
        let personal = profile(id: "personal", family: "claude")

        XCTAssertTrue(AccountUsageCardPlanner.snapshotCards(
            profiles: [personal],
            preferredProfileIDs: ["claude": personal.id],
            availableSnapshotProfileIDs: [personal.id],
            sharedHomeIdentityKeys: ["claude": personal.identityKey]
        ).isEmpty)
    }

    func testInactiveProfileWithoutSavedCredentialsIsUnavailable() {
        let personal = profile(id: "personal", family: "claude")
        let work = profile(id: "work", family: "claude")

        XCTAssertTrue(AccountUsageCardPlanner.snapshotCards(
            profiles: [personal, work],
            preferredProfileIDs: ["claude": work.id],
            availableSnapshotProfileIDs: []
        ).isEmpty)
    }

    func testArchivedProfileNeverGetsACard() {
        var archived = profile(id: "gone", family: "claude")
        archived.isArchived = true

        XCTAssertTrue(AccountUsageCardPlanner.snapshotCards(
            profiles: [archived],
            preferredProfileIDs: [:],
            availableSnapshotProfileIDs: [archived.id]
        ).isEmpty)
    }

    private func profile(id: String, family: String) -> AccountProfile {
        AccountProfile(
            id: id,
            family: family,
            label: id,
            identityKey: "identity-\(id)",
            createdAt: .distantPast
        )
    }
}
