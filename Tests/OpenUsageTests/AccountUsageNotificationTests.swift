import XCTest
@testable import OpenUsage

@MainActor
final class AccountUsageNotificationTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    private struct PostedNotification {
        let id: String
        let subtitle: String
    }

    private final class Recorder {
        var posts: [PostedNotification] = []
    }

    private final class MutableRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var used = 80.0

        init(id: String) {
            let family = ProviderAccountID.family(of: id)
            provider = Provider(id: id, displayName: family.capitalized, icon: .providerMark(family))
            widgetDescriptors = [WidgetDescriptor(
                id: "\(id).session", providerID: id, metricLabel: "Session",
                sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 80, limit: 100)
            )]
        }

        func refresh() async -> ProviderSnapshot {
            ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [.progress(
                    label: "Session", used: used, limit: 100, format: .percent,
                    resetsAt: AccountUsageNotificationTests.base.addingTimeInterval(AccountUsageNotificationTests.week * 0.10),
                    periodDurationMs: Int(AccountUsageNotificationTests.week * 1000)
                )]
            )
        }
    }

    @MainActor
    private final class Fixture {
        let profiles: AccountProfilesStore
        let runtimes: [MutableRuntime]
        let registry: WidgetRegistry
        let store: WidgetDataStore
        let recorder = Recorder()
        var profileIDs: [String: String]

        init(
            defaults: UserDefaults,
            profiles: AccountProfilesStore,
            accounts: ProviderAccountsStore,
            cardIDs: [String],
            assembly: ProviderAccountAssembly
        ) {
            self.profiles = profiles
            runtimes = cardIDs.map(MutableRuntime.init)
            registry = WidgetRegistry.from(runtimes)
            profileIDs = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)
            let settings = NotificationSettingsStore(defaults: defaults)
            settings.underTenPercent = true
            settings.healthyToClose = true
            settings.closeToRunningOut = true
            let recorder = recorder
            store = WidgetDataStore(
                registry: registry, providers: runtimes,
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
                defaults: defaults,
                notificationSettings: { settings },
                postNotification: { id, _, subtitle, _, _ in
                    recorder.posts.append(PostedNotification(id: id, subtitle: subtitle))
                    return true
                },
                providerIdentityKeys: assembly.identityKeysByCard
            )
            AppContainer.configureQuotaNotificationNames(
                dataStore: store, accounts: accounts, profiles: profiles,
                profileID: { [weak self] in self?.profileIDs[$0] }
            )
        }

        func evaluate(used: Double) async {
            for runtime in runtimes { runtime.used = used }
            await store.refreshAll(force: true)
            await store.evaluateNotifications(now: AccountUsageNotificationTests.base)
        }

        func replaceAccounts(with assembly: ProviderAccountAssembly) {
            profileIDs = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)
            store.replaceProviderCatalog(
                registry: registry, providers: runtimes, identityKeys: assembly.identityKeysByCard
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AccountUsageNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAllQuotaMilestonesIdentifyEachManagedProfile() async throws {
        for family in AccountProfilesStore.supportedFamilies {
            for sameIdentity in [false, true] {
                let defaults = makeDefaults()
                let profiles = AccountProfilesStore(defaults: defaults)
                let personal = try profiles.add(family: family, label: "Personal", identityKey: "identity-a")
                let work = try profiles.add(
                    family: family, label: "Work", identityKey: sameIdentity ? "identity-a" : "identity-b"
                )
                let snapshotID = AccountUsageCardPlanner.cardID(family: family, profileID: work.id)
                let fixture = Fixture(
                    defaults: defaults, profiles: profiles, accounts: ProviderAccountsStore(defaults: defaults),
                    cardIDs: [family, snapshotID],
                    assembly: ProviderAccountAssembly(
                        identityKeysByCard: [family: personal.identityKey, snapshotID: work.identityKey],
                        profileIDsByCard: [snapshotID: work.id]
                    )
                )

                await fixture.evaluate(used: 80)
                XCTAssertTrue(fixture.recorder.posts.isEmpty)
                await fixture.evaluate(used: 87)
                await fixture.evaluate(used: 95)

                XCTAssertEqual(fixture.recorder.posts.count, 6)
                for (cardID, profile) in [(family, personal), (snapshotID, work)] {
                    let posts = fixture.recorder.posts.filter { $0.id.hasPrefix(cardID + ".") }
                    XCTAssertEqual(Set(posts.map(\.id)), Set(PaceMilestone.allCases.map { "\(cardID).\($0.rawValue)" }))
                    XCTAssertEqual(Set(posts.map(\.subtitle)), ["\(family.capitalized) — \(profile.label) \(L10n.metrics("Session"))"])
                }
            }
        }
    }

    func testRenamedProfilesAppearInSubsequentNotificationsWithoutRebuildingTheCatalog() async throws {
        for family in AccountProfilesStore.supportedFamilies {
            let defaults = makeDefaults()
            let profiles = AccountProfilesStore(defaults: defaults)
            let personal = try profiles.add(family: family, label: "Personal", identityKey: "identity-a")
            let work = try profiles.add(family: family, label: "Work", identityKey: "identity-b")
            let snapshotID = AccountUsageCardPlanner.cardID(family: family, profileID: work.id)
            let fixture = Fixture(
                defaults: defaults, profiles: profiles, accounts: ProviderAccountsStore(defaults: defaults),
                cardIDs: [family, snapshotID],
                assembly: ProviderAccountAssembly(
                    identityKeysByCard: [family: personal.identityKey, snapshotID: work.identityKey],
                    profileIDsByCard: [snapshotID: work.id]
                )
            )
            await fixture.evaluate(used: 80)
            await fixture.evaluate(used: 87)
            XCTAssertEqual(fixture.recorder.posts.count, 2)

            try profiles.rename(profileID: personal.id, to: "개인용")
            try profiles.rename(profileID: work.id, to: "업무용")
            await fixture.evaluate(used: 80)
            await fixture.evaluate(used: 87)

            XCTAssertEqual(fixture.recorder.posts.count, 4)
            XCTAssertEqual(Set(fixture.recorder.posts.suffix(2).map(\.subtitle)), Set([
                "\(family.capitalized) — 개인용 \(L10n.metrics("Session"))",
                "\(family.capitalized) — 업무용 \(L10n.metrics("Session"))",
            ]))
        }
    }

    func testSharedCardUsesItsNewAccountNameAfterIdentityReplacement() async throws {
        for family in AccountProfilesStore.supportedFamilies {
            let defaults = makeDefaults()
            let profiles = AccountProfilesStore(defaults: defaults)
            let personal = try profiles.add(family: family, label: "Personal", identityKey: "identity-a")
            let work = try profiles.add(family: family, label: "Work", identityKey: "identity-b")
            let fixture = Fixture(
                defaults: defaults, profiles: profiles, accounts: ProviderAccountsStore(defaults: defaults),
                cardIDs: [family], assembly: ProviderAccountAssembly(identityKeysByCard: [family: personal.identityKey])
            )
            await fixture.evaluate(used: 80)
            await fixture.evaluate(used: 87)
            XCTAssertEqual(fixture.recorder.posts.count, 1)
            XCTAssertTrue(try XCTUnwrap(fixture.recorder.posts.last).subtitle.contains("Personal"))

            fixture.replaceAccounts(with: ProviderAccountAssembly(identityKeysByCard: [family: work.identityKey]))
            await fixture.evaluate(used: 95)
            XCTAssertEqual(fixture.recorder.posts.count, 1, "replacement account's first sample must only prime its baseline")
            await fixture.evaluate(used: 80)
            await fixture.evaluate(used: 87)

            XCTAssertEqual(fixture.recorder.posts.count, 2)
            XCTAssertEqual(fixture.recorder.posts.last?.subtitle, "\(family.capitalized) — Work \(L10n.metrics("Session"))")
            XCTAssertEqual(profiles.preferredProfileID(family: family), personal.id)
        }
    }

    func testUnmanagedAccountsAndOtherProvidersKeepTheirExistingNames() async throws {
        let defaults = makeDefaults()
        let accounts = ProviderAccountsStore(defaults: defaults)
        accounts.reconcile(with: [
            .init(family: "claude", identityKey: "default", label: "default@example.invalid",
                  sources: [.init(kind: .defaultHome, anchor: nil, holdsDefaultSource: true)]),
            .init(family: "claude", identityKey: "legacy", label: "Legacy", sources: []),
        ])
        let legacyID = try XCTUnwrap(accounts.records.first { $0.identityKey == "legacy" }).id
        let fixture = Fixture(
            defaults: defaults, profiles: AccountProfilesStore(defaults: defaults), accounts: accounts,
            cardIDs: ["claude", "codex", "cursor", legacyID],
            assembly: ProviderAccountAssembly(identityKeysByCard: ["claude": "default", legacyID: "legacy"])
        )
        await fixture.evaluate(used: 80)
        await fixture.evaluate(used: 87)

        XCTAssertEqual(fixture.recorder.posts.count, 4)
        XCTAssertEqual(Set(fixture.recorder.posts.map(\.subtitle)), Set([
            "Claude \(L10n.metrics("Session"))", "Codex \(L10n.metrics("Session"))",
            "Cursor \(L10n.metrics("Session"))", "Claude — Legacy \(L10n.metrics("Session"))",
        ]))
    }
}
