import XCTest
@testable import OpenUsage

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
                // Claude는 default home에서 resolve, Codex는 계정 미표기 credential
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        XCTAssertEqual(assembly.defaultHomePathsByFamily, ["claude": "/Users/dev/.claude"])
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
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

    func testAnUnregisteredConfigDirAccountIsNotSurfaced() throws {
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

        XCTAssertEqual(assembly.identityKeysByCard["claude"], "acct-1")
        XCTAssertEqual(
            store.records.map(\.id),
            ["claude"],
            "an account that is not registered never enters the registry"
        )
        XCTAssertTrue(
            assembly.hasUnregisteredClaudeLogins,
            "the other login still gates the Desktop fallback and pi totals"
        )
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

        XCTAssertFalse(assembly.hasUnregisteredClaudeLogins, "the same account is not another login")
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
                // credential은 있으나 state file에 계정 미표기 → unresolved, footprint 존재
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

        XCTAssertFalse(
            assembly.hasUnregisteredClaudeLogins,
            "with a nameless default login, an accepted candidate could be that very account — skip"
        )
        XCTAssertTrue(store.records.isEmpty)
    }

    func testNoDefaultLoginLeavesAConfigDirOnlyAccountHidden() throws {
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

        XCTAssertTrue(store.records.isEmpty, "an unregistered login stays hidden even with no default login")
        XCTAssertTrue(assembly.hasUnregisteredClaudeLogins)
    }

    func testAnUnregisteredLoginStaysHiddenAcrossLaunches() throws {
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

        let first = ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, claudeDiscovery: discovery
        )
        XCTAssertTrue(first.hasUnregisteredClaudeLogins)

        let reloadedStore = ProviderAccountsStore(defaults: defaults)
        let second = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: reloadedStore,
            claudeDiscovery: discovery
        )
        XCTAssertTrue(second.hasUnregisteredClaudeLogins, "the signal is recomputed from the scan each launch")
        XCTAssertTrue(reloadedStore.records.isEmpty, "no registry entry survives for an unregistered login")
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
            // 계정 미표기 login footprint → `.unresolved`
            files["/Users/dev/.codex/auth.json"] = #"{"tokens": {"access_token": "at-1"}}"#
        }
        return DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles(files),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
    }

    func testDefaultHomeSwapKeepsRecordsAndParksTheMovedOutAccount() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)

        _ = ProviderAccountAssembly.make(
            observer: makeCodexObserver(accountID: "CODEX-A"),
            accountsStore: store
        )
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.id, "codex")

        let second = ProviderAccountAssembly.make(
            observer: makeCodexObserver(accountID: "CODEX-B"),
            accountsStore: store
        )

        let recordA = try XCTUnwrap(store.records.first { $0.identityKey == "codex-a" })
        XCTAssertEqual(recordA.id, "codex")
        XCTAssertTrue(recordA.sources.isEmpty)
        let recordB = try XCTUnwrap(store.records.first { $0.identityKey == "codex-b" })
        XCTAssertTrue(recordB.id.hasPrefix("codex@"))
        XCTAssertTrue(recordB.sources.contains(where: \.holdsDefaultSource))
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.id, recordB.id)
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

    func testManagedProfilesRemainSeparateWhenTheHomeMatchesAnInactiveIdentity() throws {
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

        XCTAssertEqual(
            assembly.snapshotCards.map(\.profileID),
            [personal.id, work.id],
            "managed account names remain separate even when one identity is also visible in the shared home"
        )
    }

    func testDuplicateManagedIdentitiesKeepSeparateNamedSnapshotCards() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let profiles = AccountProfilesStore(defaults: defaults)
        let alpha = try profiles.add(family: "codex", label: "alpha", identityKey: "codex-shared")
        let beta = try profiles.add(family: "codex", label: "beta", identityKey: "codex-shared")
        profiles.setPreferred(family: "codex", profileID: alpha.id)

        let assembly = ProviderAccountAssembly.make(
            observer: makeCodexObserver(accountID: "CODEX-SHARED"),
            accountsStore: store,
            accountProfiles: profiles,
            managedProfiles: profiles.profiles,
            snapshotProfileIDs: [alpha.id, beta.id]
        )

        XCTAssertEqual(assembly.snapshotCards.map(\.profileID), [beta.id])
        XCTAssertEqual(assembly.profileIDsByCard.values.sorted(), [beta.id])
    }

    func testManagedProfileSuppressesADiscoveredCardWithTheSameIdentity() throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let profiles = AccountProfilesStore(defaults: defaults)
        let alpha = try profiles.add(family: "claude", label: "alpha", identityKey: "acct-1")
        let beta = try profiles.add(family: "claude", label: "beta", identityKey: "acct-2")
        profiles.setPreferred(family: "claude", profileID: alpha.id)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount":{"accountUuid":"acct-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )
        let discovery = makeDiscovery(
            files: [
                "/Users/dev/.claude-beta/.claude.json": #"{"oauthAccount":{"accountUuid":"acct-2"}}"#,
                "/Users/dev/.claude-beta/.credentials.json": #"{"claudeAiOauth":{"accessToken":"token-2"}}"#,
            ],
            subdirectories: ["/Users/dev/.claude-beta"]
        )

        let assembly = ProviderAccountAssembly.make(
            observer: observer,
            accountsStore: store,
            claudeDiscovery: discovery,
            accountProfiles: profiles,
            managedProfiles: profiles.profiles,
            snapshotProfileIDs: [alpha.id, beta.id]
        )

        XCTAssertEqual(assembly.snapshotCards.map(\.profileID), [beta.id])
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
