import XCTest
@testable import OpenUsage

@MainActor
final class AccountCardPresentationStoreTests: XCTestCase {
    private var defaults: RecordingAccountPresentationDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AccountCardPresentationStoreTests-\(UUID().uuidString)"
        defaults = RecordingAccountPresentationDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testDefaultModeAndRegistrationOrderDoNotWrite() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let older = profile("older", createdAt: 1)
        let newer = profile("newer", createdAt: 2)

        XCTAssertEqual(store.mode, .singleCard)
        XCTAssertEqual(store.orderedProfiles([newer, older], family: "claude"), [older, newer])
        store.setMode(.singleCard)
        XCTAssertEqual(defaults.presentationWriteCount, 0)
        XCTAssertNil(defaults.object(forKey: AccountCardPresentationStore.storageKey))
        XCTAssertNil(defaults.object(forKey: AccountCardPresentationStore.displayModeKey))
    }

    func testGlobalModeAndFamilyOrdersPersistIndependentlyAcrossRelaunch() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let claude = [profile("a"), profile("b", createdAt: 1)]
        let codex = [profile("c", family: "codex"), profile("d", family: "codex", createdAt: 1)]

        store.setMode(.separateCards)
        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "claude", profiles: claude + codex))
        XCTAssertTrue(store.reorder(dragged: "d", target: "c", family: "codex", profiles: claude + codex))

        let reloaded = AccountCardPresentationStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .separateCards)
        XCTAssertEqual(reloaded.effectiveMode(for: "claude", profiles: claude, registryReadable: true), .separateCards)
        XCTAssertEqual(reloaded.effectiveMode(for: "codex", profiles: codex, registryReadable: true), .separateCards)
        XCTAssertEqual(reloaded.orderedProfiles(claude + codex, family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.orderedProfiles(claude + codex, family: "codex").map(\.id), ["d", "c"])
        XCTAssertEqual(defaults.presentationWriteCount, 3)
    }

    func testUnavailableRegistryOrNoActiveProfilesOnlyChangesEffectiveMode() {
        let store = AccountCardPresentationStore(defaults: defaults)
        store.setMode(.separateCards)
        let active = profile("a")
        var archived = active
        archived.isArchived = true

        XCTAssertEqual(store.effectiveMode(for: "claude", profiles: [], registryReadable: true), .singleCard)
        XCTAssertEqual(store.effectiveMode(for: "claude", profiles: [active], registryReadable: false), .singleCard)
        XCTAssertEqual(store.effectiveMode(for: "claude", profiles: [archived], registryReadable: true), .singleCard)
        XCTAssertEqual(store.mode, .separateCards)
        XCTAssertEqual(store.effectiveMode(for: "claude", profiles: [active], registryReadable: true), .separateCards)
        XCTAssertEqual(defaults.presentationWriteCount, 1)
    }

    func testReorderUsesTargetPositionInBothDirections() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b", createdAt: 1), profile("c", createdAt: 2)]

        XCTAssertTrue(store.reorder(dragged: "a", target: "c", family: "claude", profiles: profiles))
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "c", "a"])
        XCTAssertTrue(store.reorder(dragged: "a", target: "b", family: "claude", profiles: profiles))
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["a", "b", "c"])
    }

    func testNoOpAndInvalidReorderNeverWrite() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b"), profile("other", family: "codex")]
        store.setMode(.separateCards)
        store.setMode(.separateCards)

        XCTAssertFalse(store.reorder(dragged: "a", target: "a", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "missing", target: "a", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "a", target: "missing", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "a", target: "other", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "a", target: "b", family: "cursor", profiles: profiles))
        XCTAssertEqual(defaults.presentationWriteCount, 1)
    }

    func testStaleForeignAndDuplicateSavedIDsAreIgnoredAndNewProfilesAppend() throws {
        try seed(modes: [:], orders: ["claude": ["missing", "c", "other", "c", "a", "archived"]])
        let store = AccountCardPresentationStore(defaults: defaults)
        var archived = profile("archived")
        archived.isArchived = true
        let profiles = [
            profile("a"), profile("b", createdAt: 1), profile("c", createdAt: 2),
            profile("new", createdAt: 3), profile("other", family: "codex"), archived,
        ]

        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["c", "a", "b", "new"])
        XCTAssertEqual(store.orderedProfiles(profiles, family: "codex").map(\.id), ["other"])
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testEqualRegistrationDatesRetainRegistryOrder() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("z"), profile("a"), profile("m")]

        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude"), profiles)
    }

    func testMissingProfilesDoNotEraseSavedRankOnRead() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b", createdAt: 1)]
        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "claude", profiles: profiles))

        XCTAssertEqual(store.orderedProfiles([profiles[0]], family: "claude").map(\.id), ["a"])
        XCTAssertTrue(store.orderedProfiles([], family: "claude").isEmpty)
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(defaults.presentationWriteCount, 1)
    }

    func testRenameIdentityReplacementSelectionAndModeChangesPreserveRank() throws {
        let profiles = AccountProfilesStore(defaults: defaults)
        let first = try profiles.add(family: "claude", label: "First", identityKey: "one")
        let second = try profiles.add(family: "claude", label: "Second", identityKey: "two")
        let store = AccountCardPresentationStore(defaults: defaults)
        XCTAssertTrue(store.reorder(dragged: second.id, target: first.id, family: "claude", profiles: profiles.profiles))

        try profiles.rename(profileID: second.id, to: "Renamed")
        _ = try profiles.replaceIdentity(profileID: second.id, with: "new-identity")
        profiles.setPreferred(family: "claude", profileID: second.id)
        store.setMode(.separateCards)
        store.setMode(.singleCard)

        XCTAssertEqual(store.orderedProfiles(profiles.profiles, family: "claude").map(\.id), [second.id, first.id])
        XCTAssertEqual(store.orderedProfiles(profiles.profiles, family: "claude").first?.label, "Renamed")
    }

    func testPresentationWritesLeaveAccountSelectionLayoutAndOtherDefaultsUntouched() throws {
        let registry = AccountProfilesStore(defaults: defaults)
        let first = try registry.add(family: "claude", label: "First", identityKey: "one")
        let second = try registry.add(family: "claude", label: "Second", identityKey: "two")
        registry.setPreferred(family: "claude", profileID: first.id)
        defaults.set("existing-layout", forKey: "openusage.layout.v1")
        DashboardUsageAccountSelection.select("claude", for: "claude", defaults: defaults)
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]
        let store = AccountCardPresentationStore(defaults: defaults)

        store.setMode(.separateCards)
        XCTAssertTrue(store.reorder(dragged: second.id, target: first.id, family: "claude", profiles: registry.profiles))

        var after = defaults.persistentDomain(forName: suiteName) ?? [:]
        after.removeValue(forKey: AccountCardPresentationStore.storageKey)
        after.removeValue(forKey: AccountCardPresentationStore.displayModeKey)
        XCTAssertEqual(before as NSDictionary, after as NSDictionary)
        XCTAssertEqual(registry.preferredProfileID(family: "claude"), first.id)
    }

    func testCorruptPreferencesAreReportedAndNeverOverwritten() {
        let raw = Data("not valid JSON".utf8)
        defaults.set(raw, forKey: AccountCardPresentationStore.storageKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b")]

        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(store.mode, .singleCard)
        store.setMode(.separateCards)
        XCTAssertFalse(store.reorder(dragged: "b", target: "a", family: "claude", profiles: profiles))
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), raw)
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testWrongDefaultsTypeIsReportedAndPreserved() {
        defaults.set("unexpected type", forKey: AccountCardPresentationStore.storageKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertNotNil(store.errorMessage)
        store.setMode(.separateCards)
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.storageKey), "unexpected type")
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testUnsupportedModeAndFamilySurviveUnrelatedWritesUntilExplicitlyReplaced() throws {
        try seed(modes: ["claude": "futureMode", "future": "futureMode"], orders: ["future": ["future-profile"]])
        let store = AccountCardPresentationStore(defaults: defaults)
        XCTAssertEqual(store.mode, .singleCard)
        XCTAssertNotNil(store.errorMessage)

        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "codex", profiles: [
            profile("a", family: "codex"), profile("b", family: "codex"),
        ]))
        let stored = try storedObject()
        XCTAssertEqual(stored["modesByFamily"] as? [String: String], ["claude": "futureMode", "future": "futureMode"])
        XCTAssertEqual(stored["profileOrderByFamily"] as? [String: [String]], [
            "future": ["future-profile"], "codex": ["b", "a"],
        ])
        XCTAssertNotNil(store.errorMessage)

        let legacyBefore = defaults.data(forKey: AccountCardPresentationStore.storageKey)
        store.setMode(.singleCard)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.mode, .singleCard)
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), legacyBefore)
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.displayModeKey), "singleCard")
    }

    func testLegacySeparateModeIsInheritedFromEitherFamilyWithoutWriting() throws {
        for family in AccountProfilesStore.supportedFamilies {
            try seed(modes: [family: "separateCards"], orders: ["claude": ["b", "a"]])
            let legacyBefore = defaults.data(forKey: AccountCardPresentationStore.storageKey)
            let store = AccountCardPresentationStore(defaults: defaults)

            XCTAssertEqual(store.mode, .separateCards)
            XCTAssertEqual(store.orderedProfiles([profile("a"), profile("b")], family: "claude").map(\.id), ["b", "a"])
            store.setMode(.separateCards)
            XCTAssertNil(defaults.object(forKey: AccountCardPresentationStore.displayModeKey))
            XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), legacyBefore)
            XCTAssertEqual(defaults.presentationWriteCount, 0)
        }
    }

    func testLegacySingleModesAndUnsupportedFamiliesDoNotEnableSeparateCards() throws {
        try seed(modes: ["claude": "singleCard", "codex": "singleCard", "future": "separateCards"], orders: [:])

        XCTAssertEqual(AccountCardPresentationStore(defaults: defaults).mode, .singleCard)
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testExplicitGlobalModeWinsWithoutChangingLegacySettingsOrAccountOrders() throws {
        try seed(modes: ["claude": "separateCards", "codex": "singleCard"], orders: ["codex": ["b", "a"]])
        let legacyBefore = defaults.data(forKey: AccountCardPresentationStore.storageKey)
        let store = AccountCardPresentationStore(defaults: defaults)

        store.setMode(.singleCard)

        let reloaded = AccountCardPresentationStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .singleCard)
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), legacyBefore)
        XCTAssertEqual(reloaded.orderedProfiles([
            profile("a", family: "codex"), profile("b", family: "codex"),
        ], family: "codex").map(\.id), ["b", "a"])

        reloaded.setMode(.separateCards)
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), legacyBefore)
        XCTAssertEqual(AccountCardPresentationStore(defaults: defaults).mode, .separateCards)
    }

    func testOldVersionWritingLegacyBlobCannotEraseExplicitGlobalMode() throws {
        let store = AccountCardPresentationStore(defaults: defaults)
        store.setMode(.separateCards)

        try seed(modes: ["claude": "singleCard", "codex": "singleCard"], orders: ["claude": ["b", "a"]])

        let reloaded = AccountCardPresentationStore(defaults: defaults)
        XCTAssertEqual(reloaded.mode, .separateCards)
        XCTAssertEqual(reloaded.orderedProfiles([profile("a"), profile("b")], family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testExplicitSupportedGlobalModeSuppressesLegacyUnknownModeWarning() throws {
        try seed(modes: ["claude": "futureMode"], orders: [:])
        defaults.set("separateCards", forKey: AccountCardPresentationStore.displayModeKey)

        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertEqual(store.mode, .separateCards)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(try storedObject()["modesByFamily"] as? [String: String], ["claude": "futureMode"])
    }

    func testUnknownGlobalModeHasPriorityAndIsPreservedUntilExplicitSelection() throws {
        try seed(modes: ["claude": "separateCards"], orders: [:])
        defaults.set("futureGlobalMode", forKey: AccountCardPresentationStore.displayModeKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertEqual(store.mode, .singleCard)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "claude", profiles: [profile("a"), profile("b")]))
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.displayModeKey), "futureGlobalMode")
        XCTAssertNotNil(store.errorMessage)

        store.setMode(.singleCard)
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.displayModeKey), "singleCard")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(defaults.presentationWriteCount, 2)
    }

    func testMalformedGlobalModeIsPreservedUntilExplicitSelection() {
        defaults.set(42, forKey: AccountCardPresentationStore.displayModeKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertEqual(store.mode, .singleCard)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(defaults.integer(forKey: AccountCardPresentationStore.displayModeKey), 42)
        XCTAssertEqual(defaults.presentationWriteCount, 0)

        store.setMode(.singleCard)
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.displayModeKey), "singleCard")
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(defaults.presentationWriteCount, 1)
    }

    func testCorruptLegacySettingsRetainExplicitGlobalModeAndBlockAllWrites() {
        let legacy = Data("corrupt legacy".utf8)
        defaults.set(legacy, forKey: AccountCardPresentationStore.storageKey)
        defaults.set("separateCards", forKey: AccountCardPresentationStore.displayModeKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertEqual(store.mode, .separateCards)
        XCTAssertNotNil(store.errorMessage)
        store.setMode(.singleCard)
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), legacy)
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.displayModeKey), "separateCards")
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testDisplayModeControlRequiresTwoActiveProfilesWithinOneSupportedFamily() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let claude = [profile("a"), profile("b")]
        let codex = [profile("c", family: "codex"), profile("d", family: "codex")]
        var archived = profile("archived")
        archived.isArchived = true

        XCTAssertFalse(store.shouldShowDisplayMode(profiles: [], registryReadable: true))
        XCTAssertFalse(store.shouldShowDisplayMode(profiles: [claude[0]], registryReadable: true))
        XCTAssertFalse(store.shouldShowDisplayMode(profiles: [claude[0], codex[0]], registryReadable: true))
        XCTAssertFalse(store.shouldShowDisplayMode(profiles: [claude[0], archived], registryReadable: true))
        XCTAssertFalse(store.shouldShowDisplayMode(profiles: [
            profile("x", family: "cursor"), profile("y", family: "cursor"),
        ], registryReadable: true))
        XCTAssertTrue(store.shouldShowDisplayMode(profiles: claude, registryReadable: true))
        XCTAssertTrue(store.shouldShowDisplayMode(profiles: codex, registryReadable: true))
        XCTAssertTrue(store.shouldShowDisplayMode(profiles: claude + codex, registryReadable: true))
        XCTAssertFalse(store.shouldShowDisplayMode(profiles: claude + codex, registryReadable: false))
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testHidingDisplayModeControlPreservesModeAndAccountOrder() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b")]
        store.setMode(.separateCards)
        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "claude", profiles: profiles))

        XCTAssertFalse(store.shouldShowDisplayMode(profiles: [profiles[0]], registryReadable: true))
        XCTAssertFalse(store.shouldShowDisplayMode(profiles: profiles, registryReadable: false))
        XCTAssertEqual(store.mode, .separateCards)
        XCTAssertTrue(store.shouldShowDisplayMode(profiles: profiles, registryReadable: true))
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(defaults.presentationWriteCount, 2)
    }

    private func profile(_ id: String, family: String = "claude", createdAt: TimeInterval = 0) -> AccountProfile {
        AccountProfile(id: id, family: family, label: id, identityKey: "identity-\(id)", createdAt: Date(timeIntervalSince1970: createdAt))
    }

    private func seed(modes: [String: String], orders: [String: [String]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["modesByFamily": modes, "profileOrderByFamily": orders])
        defaults.set(data, forKey: AccountCardPresentationStore.storageKey)
        defaults.presentationWriteCount = 0
    }

    private func storedObject() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: AccountCardPresentationStore.storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class RecordingAccountPresentationDefaults: UserDefaults {
    var presentationWriteCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if ["openusage.accountCardPresentation.v1", "openusage.accountCardDisplayMode.v1"].contains(defaultName) {
            presentationWriteCount += 1
        }
        super.set(value, forKey: defaultName)
    }
}
