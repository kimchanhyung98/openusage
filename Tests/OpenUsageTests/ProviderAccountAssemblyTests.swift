import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        XCTAssertEqual(assembly.defaultHomePathsByFamily, ["claude": "/Users/dev/.claude"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    func testCodexDefaultHomePathTracksTheResolvedConfigHome() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.config/codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CONFIG-CODEX"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "LEGACY-CODEX"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.defaultHomePathsByFamily["codex"], "/Users/dev/.config/codex")
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "config-codex")
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    private func makeDiscovery(
        files: [String: String],
        subdirectories: [String]
    ) -> ClaudeConfigDirDiscovery {
        ClaudeConfigDirDiscovery(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: ServiceKeychain(),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") },
            listSubdirectories: { url in
                subdirectories
                    .map { URL(fileURLWithPath: $0) }
                    .filter { $0.deletingLastPathComponent().path == url.path }
            }
        )
    }

    func testADistinctConfigDirAccountMintsAHashedRecordAndAnExtraCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2", "emailAddress": "work@example.com", "organizationName": "Sunstory"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertEqual(assembly.claudeCards.count, 1)
        XCTAssertTrue(card.id.hasPrefix("claude@"), "a config-dir account never claims the bare id")
        XCTAssertEqual(card.displayName, "Claude — Sunstory")
        XCTAssertEqual(card.configDirPath, "/Users/dev/.claude-work")
        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1")
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-2")
        // The registry recorded both: the default holder under the bare id, the extra account with
        // its config-dir source.
        let record = try XCTUnwrap(store.records.first { $0.id == card.id })
        XCTAssertEqual(record.sources.map(\.kind), [.configDir])
        XCTAssertEqual(record.label, "work@example.com (Sunstory)")
        XCTAssertTrue(assembly.defaultClaudeExtraLogRoots.isEmpty)
    }

    func testASameAccountConfigDirFoldsOntoTheDefaultCardAsALogRoot() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-side/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.claude-side/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-side"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(assembly.claudeCards.isEmpty, "one account never renders as two cards")
        XCTAssertEqual(assembly.defaultClaudeExtraLogRoots.map(\.path), ["/Users/dev/.claude-side"])
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(Set(record.sources.map(\.kind)), [.defaultHome, .configDir])
    }

    func testAnUnresolvedDefaultLoginSkipsCandidatesThisLaunch() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Credentials exist but the state file names no account → unresolved, footprint present.
                "/Users/dev/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        XCTAssertTrue(
            assembly.claudeCards.isEmpty,
            "with a nameless default login, an accepted candidate could be that very account — skip"
        )
        XCTAssertTrue(store.records.isEmpty)
    }

    func testNoDefaultLoginStillAcceptsAConfigDirOnlyAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )

        let card = try XCTUnwrap(assembly.claudeCards.first)
        XCTAssertTrue(
            card.id.hasPrefix("claude@"),
            "the bare id stays reserved for a future default-home login even when it is free"
        )
    }

    func testARenameNeverBakesIntoTheCardOnlyTheResolverCarriesIt() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-work/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-2"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "at-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-work"]
        )

        // First pass creates the record; the user then renames it.
        let first = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        let cardID = try XCTUnwrap(first.claudeCards.first?.id)
        XCTAssertEqual(first.claudeCards.first?.displayName, cardID, "no label → the short-hash id fallback")
        store.rename(cardID: cardID, to: "Work Max")

        let reloadedStore = ProviderAccountsStore(defaults: defaults)
        let second = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: reloadedStore,
            claudeDiscovery: discovery
        )
        // The baked card name stays the DERIVED default — a rename lives only in the registry and
        // is resolved at render time, so a baked name can never be a stale copy of it.
        XCTAssertEqual(second.claudeCards.first?.displayName, cardID)
        XCTAssertEqual(reloadedStore.resolvedDisplayName(cardID: cardID), "Work Max")
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }

    // MARK: - Default-home swap

    private func makeCodexObserver(accountID: String?) -> DefaultAccountObserver {
        var files: [String: String] = [:]
        if let accountID {
            files["/Users/dev/.codex/auth.json"] =
                #"{"tokens": {"access_token": "at-1", "account_id": "\#(accountID)"}}"#
        } else {
            // A login footprint that names no account → `.unresolved`.
            files["/Users/dev/.codex/auth.json"] = #"{"tokens": {"access_token": "at-1"}}"#
        }
        return DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
    }

    /// Default-home login swap: the moved-out account keeps its record id (badge and source edge
    /// gone), the new account mints `codex@hash8` and takes the badge — and the parked bare record
    /// renders no card until Phase 4 swap support.
    func testDefaultHomeSwapKeepsRecordsAndParksTheMovedOutAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)

        // Launch 1: account A holds the default home.
        _ = ProviderAccountAssembly.make(
            observer: makeCodexObserver(accountID: "CODEX-A"),
            accountsStore: store
        )
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.id, "codex")

        // Launch 2: account B holds the default home.
        let second = ProviderAccountAssembly.make(
            observer: makeCodexObserver(accountID: "CODEX-B"),
            accountsStore: store
        )

        // A's record survives under the bare id; the default-home source edge moved to B.
        let recordA = try XCTUnwrap(store.records.first { $0.identityKey == "codex-a" })
        XCTAssertEqual(recordA.id, "codex")
        XCTAssertTrue(recordA.sources.isEmpty)
        // B mints a hashed id and takes the default badge.
        let recordB = try XCTUnwrap(store.records.first { $0.identityKey == "codex-b" })
        XCTAssertTrue(recordB.id.hasPrefix("codex@"))
        XCTAssertTrue(recordB.sources.contains(where: \.holdsDefaultSource))
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.id, recordB.id)
        // The default card is stamped with the account actually holding the default home — note
        // the bare id now names B's key even though A's record still holds it; that divergence is
        // exactly what Phase 4 re-points.
        XCTAssertEqual(second.identityKeysByCard["codex"], "codex-b")
    }

    // MARK: - Snapshot cards

    func testInactiveProfileSnapshotIsExposedToTheDashboardAssembly() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let profiles = AccountProfilesStore(defaults: defaults)
        let personal = try profiles.add(family: "claude", label: "default", identityKey: "acct-1")
        let work = try profiles.add(family: "claude", label: "wv7777", identityKey: "acct-2")
        profiles.setPreferred(family: "claude", profileID: work.id)

        let assembly = ProviderAccountAssembly.make(
            observer: DefaultAccountObserver(
                environment: FakeEnvironment([:]),
                files: FakeFiles([:]),
                keychain: FakeKeychain(nil),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
            ),
            accountsStore: store,
            families: [],
            accountProfiles: profiles,
            managedProfiles: profiles.profiles,
            snapshotProfileIDs: [personal.id]
        )

        let card = try XCTUnwrap(assembly.snapshotCards.first)
        XCTAssertEqual(assembly.snapshotCards.count, 1)
        XCTAssertEqual(card.family, "claude")
        XCTAssertEqual(card.profileID, personal.id)
        XCTAssertEqual(card.id, "claude@profile-\(personal.id)")
        XCTAssertEqual(assembly.profileIDsByCard[card.id], personal.id)
        XCTAssertEqual(assembly.identityKeysByCard[card.id], "acct-1")
    }

    /// A profile whose account is already visible through a home-backed card this launch (here:
    /// the default home) must not render a duplicate snapshot card.
    func testSnapshotCardIsSuppressedWhenTheAccountAlreadyHasAHomeBackedCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let profiles = AccountProfilesStore(defaults: defaults)
        let personal = try profiles.add(family: "codex", label: "default", identityKey: "codex-1")
        let work = try profiles.add(family: "codex", label: "Work", identityKey: "codex-2")
        profiles.setPreferred(family: "codex", profileID: work.id)

        let assembly = ProviderAccountAssembly.make(
            observer: makeCodexObserver(accountID: "CODEX-1"),
            accountsStore: store,
            accountProfiles: profiles,
            managedProfiles: profiles.profiles,
            snapshotProfileIDs: [personal.id, work.id]
        )

        XCTAssertTrue(
            assembly.snapshotCards.isEmpty,
            "the inactive profile's account is the observed default login — a snapshot card would render it twice"
        )
    }

    func testPreferredProfileNeverGetsASnapshotCard() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let profiles = AccountProfilesStore(defaults: defaults)
        let personal = try profiles.add(family: "claude", label: "default", identityKey: "acct-1")
        profiles.setPreferred(family: "claude", profileID: personal.id)

        let assembly = ProviderAccountAssembly.make(
            observer: DefaultAccountObserver(
                environment: FakeEnvironment([:]),
                files: FakeFiles([:]),
                keychain: FakeKeychain(nil),
                homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
            ),
            accountsStore: store,
            families: [],
            accountProfiles: profiles,
            managedProfiles: profiles.profiles,
            snapshotProfileIDs: [personal.id]
        )

        XCTAssertTrue(
            assembly.snapshotCards.isEmpty,
            "the selected profile renders through the family's shared-home runtime, never a duplicate card"
        )
    }
}
