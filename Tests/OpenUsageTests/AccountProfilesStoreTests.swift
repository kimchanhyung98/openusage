import XCTest
@testable import OpenUsage

@MainActor
final class AccountProfilesStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AccountProfilesStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Add

    func testAddMintsAStableIDAndNormalizesIdentity() throws {
        let store = AccountProfilesStore(defaults: defaults)

        let profile = try store.add(family: "claude", label: "  Personal  ", identityKey: " Acct-A|Org-A ")

        XCTAssertFalse(profile.id.isEmpty)
        XCTAssertEqual(profile.label, "Personal")
        XCTAssertEqual(profile.identityKey, "acct-a|org-a")
        XCTAssertEqual(store.profiles(family: "claude").map(\.id), [profile.id])
    }

    func testAddAcceptsAnExplicitIDAndRejectsACollision() throws {
        let store = AccountProfilesStore(defaults: defaults)

        let first = try store.add(family: "codex", label: "One", identityKey: "acct-1", id: "fixed-id")
        XCTAssertEqual(first.id, "fixed-id")
        XCTAssertThrowsError(
            try store.add(family: "codex", label: "Two", identityKey: "acct-2", id: "fixed-id")
        )
    }

    func testAddRejectsUnknownFamilyBlankLabelAndOverlongLabel() {
        let store = AccountProfilesStore(defaults: defaults)

        XCTAssertThrowsError(try store.add(family: "cursor", label: "A", identityKey: "x")) {
            XCTAssertEqual($0 as? AccountProfileError, .unknownFamily("cursor"))
        }
        XCTAssertThrowsError(try store.add(family: "claude", label: "   ", identityKey: "x")) {
            XCTAssertEqual($0 as? AccountProfileError, .invalidLabel)
        }
        XCTAssertThrowsError(
            try store.add(family: "claude", label: String(repeating: "a", count: 61), identityKey: "x")
        ) {
            XCTAssertEqual($0 as? AccountProfileError, .invalidLabel)
        }
    }

    func testAddRejectsADuplicateAccountIdentity() throws {
        let store = AccountProfilesStore(defaults: defaults)
        _ = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")

        XCTAssertThrowsError(try store.add(family: "claude", label: "Work", identityKey: "ACCT-A")) {
            XCTAssertEqual($0 as? AccountProfileError, .duplicateAccount(existingLabel: "Personal"))
        }
        // The same identity is a separate account under the other family.
        XCTAssertNoThrow(try store.add(family: "codex", label: "Work", identityKey: "acct-a"))
    }

    func testAddRejectsADuplicateLabelCaseInsensitively() throws {
        let store = AccountProfilesStore(defaults: defaults)
        _ = try store.add(family: "claude", label: "Work", identityKey: "acct-a")

        XCTAssertThrowsError(try store.add(family: "claude", label: "work", identityKey: "acct-b")) {
            XCTAssertEqual($0 as? AccountProfileError, .duplicateLabel("work"))
        }
        // The same label is fine on the other family.
        XCTAssertNoThrow(try store.add(family: "codex", label: "Work", identityKey: "acct-b"))
    }

    func testAddEnforcesThePerFamilyLimit() throws {
        let store = AccountProfilesStore(defaults: defaults)
        for index in 0..<AccountProfilesStore.maxProfilesPerFamily {
            _ = try store.add(family: "claude", label: "Account \(index)", identityKey: "acct-\(index)")
        }

        XCTAssertThrowsError(try store.add(family: "claude", label: "Overflow", identityKey: "acct-x")) {
            XCTAssertEqual(
                $0 as? AccountProfileError,
                .accountLimitReached(AccountProfilesStore.maxProfilesPerFamily)
            )
        }
    }

    // MARK: - Selection

    func testFirstProfileIsSelectedAndAddingAnotherPreservesIt() throws {
        let store = AccountProfilesStore(defaults: defaults)

        let first = try store.add(family: "codex", label: "Personal", identityKey: "acct-a")
        XCTAssertEqual(store.preferredProfileID(family: "codex"), first.id)

        _ = try store.add(family: "codex", label: "Work", identityKey: "acct-b")
        XCTAssertEqual(store.preferredProfileID(family: "codex"), first.id)
    }

    func testSetPreferredIgnoresUnknownOrCrossFamilyIDs() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let claude = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")
        let codex = try store.add(family: "codex", label: "Personal", identityKey: "acct-b")

        store.setPreferred(family: "claude", profileID: "missing")
        store.setPreferred(family: "claude", profileID: codex.id)

        XCTAssertEqual(store.preferredProfileID(family: "claude"), claude.id)
    }

    // MARK: - Rename

    func testRenameChangesOnlyTheLabel() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")
        _ = try store.add(family: "claude", label: "Work", identityKey: "acct-b")
        store.setPreferred(family: "claude", profileID: profile.id)

        try store.rename(profileID: profile.id, to: "  Home  ")

        let renamed = try XCTUnwrap(store.profile(id: profile.id))
        XCTAssertEqual(renamed.label, "Home")
        XCTAssertEqual(renamed.id, profile.id)
        XCTAssertEqual(renamed.identityKey, profile.identityKey)
        XCTAssertEqual(renamed.createdAt, profile.createdAt)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
    }

    func testRenameRejectsADuplicateLabel() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")
        _ = try store.add(family: "claude", label: "Work", identityKey: "acct-b")

        XCTAssertThrowsError(try store.rename(profileID: profile.id, to: "WORK")) {
            XCTAssertEqual($0 as? AccountProfileError, .duplicateLabel("WORK"))
        }
        XCTAssertEqual(store.profile(id: profile.id)?.label, "Personal")
    }

    // MARK: - Archive

    func testArchivingTheSelectedProfileRequiresSwitchingFirst() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let personal = try store.add(family: "codex", label: "Personal", identityKey: "acct-a")
        let work = try store.add(family: "codex", label: "Work", identityKey: "acct-b")

        XCTAssertThrowsError(try store.archive(profileID: personal.id)) {
            XCTAssertEqual($0 as? AccountProfileError, .removeSelectedProfile)
        }

        store.setPreferred(family: "codex", profileID: work.id)
        XCTAssertNoThrow(try store.archive(profileID: personal.id))
        XCTAssertEqual(store.profiles(family: "codex").map(\.id), [work.id])
        XCTAssertEqual(store.preferredProfileID(family: "codex"), work.id)
    }

    func testArchivingTheOnlyProfileClearsTheSelection() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let personal = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")

        try store.archive(profileID: personal.id)

        XCTAssertTrue(store.profiles(family: "claude").isEmpty)
        XCTAssertNil(store.preferredProfileID(family: "claude"))
        // The account can be registered again after removal.
        XCTAssertNoThrow(try store.add(family: "claude", label: "Personal", identityKey: "acct-a"))
    }

    // MARK: - Resolve

    func testResolveByIDOrLabel() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let personal = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")

        XCTAssertEqual(try store.resolve(reference: personal.id, family: "claude").id, personal.id)
        XCTAssertEqual(try store.resolve(reference: "personal", family: "claude").id, personal.id)
        XCTAssertThrowsError(try store.resolve(reference: "missing", family: "claude")) {
            XCTAssertEqual($0 as? AccountProfileError, .profileNotFound("missing"))
        }
    }

    // MARK: - Persistence

    func testProfilesPersistAcrossInstancesAndReloadPicksUpExternalWrites() throws {
        let store = AccountProfilesStore(defaults: defaults)
        let profile = try store.add(family: "claude", label: "Personal", identityKey: "acct-a")

        let second = AccountProfilesStore(defaults: defaults)
        XCTAssertEqual(second.profiles(family: "claude").map(\.id), [profile.id])

        _ = try second.add(family: "claude", label: "Work", identityKey: "acct-b")
        store.reloadFromDefaults()
        XCTAssertEqual(store.profiles(family: "claude").count, 2)
    }

    func testStorageContractIsPinned() throws {
        let store = AccountProfilesStore(defaults: defaults)
        _ = try store.add(family: "claude", label: "Personal", identityKey: "acct-a", id: "pinned-id")

        let data = try XCTUnwrap(defaults.data(forKey: AccountProfilesStore.storageKey))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(
            Set(profiles[0].keys),
            ["id", "family", "label", "identityKey", "createdAt", "isArchived"]
        )
        XCTAssertEqual(profiles[0]["id"] as? String, "pinned-id")
        let preferred = try XCTUnwrap(object["preferredByFamily"] as? [String: String])
        XCTAssertEqual(preferred, ["claude": "pinned-id"])
    }

    func testUndecodableBlobIsPreservedAndRejectsWrites() {
        let original = Data("not json".utf8)
        defaults.set(original, forKey: AccountProfilesStore.storageKey)

        let store = AccountProfilesStore(defaults: defaults)

        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(store.hasUnreadableRegistry)
        XCTAssertThrowsError(
            try store.add(family: "claude", label: "Personal", identityKey: "acct-a")
        ) { error in
            XCTAssertEqual(error as? AccountProfileError, .registryUnreadable)
        }
        XCTAssertEqual(defaults.data(forKey: AccountProfilesStore.storageKey), original)
    }

    func testInvalidDuplicateAndOverLimitRecordsPreserveTheBlobAndBlockWrites() throws {
        var profiles: [[String: Any]] = [
            profileJSON(id: "keep", family: "claude", label: "Personal", identityKey: "acct-a"),
            // Duplicate identity within the family is discarded.
            profileJSON(id: "dup-identity", family: "claude", label: "Copy", identityKey: "ACCT-A"),
            // Duplicate label within the family is discarded.
            profileJSON(id: "dup-label", family: "claude", label: "personal", identityKey: "acct-b"),
            // Unsupported family is discarded.
            profileJSON(id: "bad-family", family: "cursor", label: "X", identityKey: "acct-c"),
            // Empty identity is discarded.
            profileJSON(id: "no-identity", family: "claude", label: "Empty", identityKey: "  "),
        ]
        for index in 0..<(AccountProfilesStore.maxProfilesPerFamily + 2) {
            profiles.append(profileJSON(
                id: "codex-\(index)",
                family: "codex",
                label: "Account \(index)",
                identityKey: "codex-acct-\(index)"
            ))
        }
        let blob: [String: Any] = ["profiles": profiles, "preferredByFamily": ["claude": "keep"]]
        let original = try JSONSerialization.data(withJSONObject: blob)
        defaults.set(original, forKey: AccountProfilesStore.storageKey)

        let store = AccountProfilesStore(defaults: defaults)

        XCTAssertTrue(store.hasUnreadableRegistry)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertThrowsError(
            try store.add(family: "claude", label: "Another", identityKey: "acct-z")
        ) { error in
            XCTAssertEqual(error as? AccountProfileError, .registryUnreadable)
        }
        XCTAssertEqual(defaults.data(forKey: AccountProfilesStore.storageKey), original)
    }

    private func profileJSON(id: String, family: String, label: String, identityKey: String) -> [String: Any] {
        [
            "id": id,
            "family": family,
            "label": label,
            "identityKey": identityKey,
            "createdAt": 0,
            "isArchived": false,
        ]
    }
}
