import XCTest
@testable import OpenUsage

@MainActor
final class PeerHistoryIdentityTests: XCTestCase {
    private let teamKey = "uuid-me|org-team"
    private let maxKey = "uuid-me|org-max"

    func testDocumentV2AllowsAccountCardsAndV1StaysStrict() throws {
        var v2 = makeDocument(providers: [
            "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
            "claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2),
        ], identities: ["claude": maxKey, "claude@ab12cd34": teamKey])
        XCTAssertNoThrow(try v2.validate())

        v2.schema = UsageHistoryDocument.legacySchemaV1
        XCTAssertThrowsError(try v2.validate())

        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "n", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        XCTAssertNoThrow(try v1.validate())
    }

    func testRemapMatchesAccountsAcrossDefaultAndExtraCardRoles() {
        let miniDoc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude": history(day: "2026-07-16", tokens: 100, cost: 502.34),
                "claude@b2d3867d": history(day: "2026-07-16", tokens: 90, cost: 494.27),
            ],
            identities: ["claude": teamKey, "claude@b2d3867d": maxKey]
        )
        let localMap = ["claude": maxKey, "claude@f15456b0": teamKey]

        let remapped = PeerHistoryRemapper.remap(documents: [miniDoc], localIdentityByCardID: localMap)

        XCTAssertTrue(remapped.remoteOnly.isEmpty)
        let byCard = Dictionary(grouping: remapped.histories, by: { $0.cardID })
        XCTAssertEqual(byCard["claude"]?.first?.history.series.daily.first?.costUSD, 494.27, "mini's Max spend belongs to this Mac's default (Max) card")
        XCTAssertEqual(byCard["claude@f15456b0"]?.first?.history.series.daily.first?.costUSD, 502.34, "mini's Team spend belongs to this Mac's Team card")
    }

    func testRemapCollectsRemoteOnlyAccounts() {
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: "2026-07-16", tokens: 50, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": maxKey]
        )
        XCTAssertTrue(remapped.histories.isEmpty)
        XCTAssertEqual(remapped.remoteOnly.count, 1)
        XCTAssertEqual(remapped.remoteOnly.first?.family, "claude")
        XCTAssertEqual(
            remapped.remoteOnly.first?.cardID,
            ProviderAccountID.make(family: "claude", identityKey: "uuid-other|org-x"),
            "the slice id is the same id the account's card gets on any Mac it's signed in on"
        )
    }

    func testUnresolvedLocalIdentityKeepsTheBareCardMergeInsteadOfDoubleCounting() {
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: ["claude": teamKey]
        )
        let remapped = PeerHistoryRemapper.remap(documents: [doc], localIdentityByCardID: [:])

        XCTAssertEqual(remapped.histories.first?.cardID, "claude")
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
    }

    func testRemapLegacyV1DocumentKeepsSameCardMerge() {
        let v1 = UsageHistoryDocument(
            schema: UsageHistoryDocument.legacySchemaV1,
            deviceID: "d", deviceName: "old Mac", updatedAt: Date(),
            providers: ["claude": history(day: "2026-07-16", tokens: 10, cost: 1)],
            identities: nil
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [v1],
            localIdentityByCardID: ["claude": maxKey]
        )
        XCTAssertEqual(remapped.histories.first?.cardID, "claude")
        XCTAssertTrue(remapped.remoteOnly.isEmpty)
    }

    func testLocalDocumentPublishesAccountCardsWithIdentities() {
        let registry = makeRegistry()
        // cache 선적재 — entry의 account stamp가 store 기동 값과 같아야 swap guard를 통과
        let cache = scratchCache()
        cache.store(
            snapshot(providerID: "claude", history: history(day: "2026-07-16", tokens: 10, cost: 1)),
            producedByIdentityKey: maxKey
        )
        cache.store(
            snapshot(providerID: "claude@f15456b0", history: history(day: "2026-07-16", tokens: 20, cost: 2)),
            producedByIdentityKey: teamKey
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("PublishDoc"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertEqual(document.schema, UsageHistoryDocument.currentSchema)
        XCTAssertNotNil(document.providers["claude@f15456b0"], "account cards sync now")
        XCTAssertEqual(document.identities?["claude"], maxKey)
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey)
        XCTAssertNoThrow(try document.validate())
    }

    func testManagedFamilyTotalExportsWithoutTheSelectedProfilesIdentity() {
        let registry = makeRegistry()
        let cache = scratchCache()
        cache.store(
            snapshot(providerID: "claude", history: history(day: "2026-07-16", tokens: 10, cost: 1)),
            producedByIdentityKey: maxKey
        )
        cache.store(
            snapshot(providerID: "claude@f15456b0", history: history(day: "2026-07-16", tokens: 20, cost: 2)),
            producedByIdentityKey: teamKey
        )
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: cache,
            defaults: makeScratchDefaults("FamilyTotalDoc"),
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey],
            familyTotalHistoryCardIDs: ["claude"]
        )

        let document = dataStore.localHistoryDocument(deviceID: "dev", deviceName: "This Mac")
        XCTAssertNotNil(document.providers["claude"], "the family total itself still syncs")
        XCTAssertNil(document.identities?["claude"],
                     "the managed family total must not be attributed to the selected account")
        XCTAssertEqual(document.identities?["claude@f15456b0"], teamKey,
                       "an account-pinned discovery card keeps its identity mapping")
        XCTAssertNoThrow(try document.validate())
    }

    func testPeerFamilyTotalWithoutIdentityMergesIntoTheBareFamilyCard() {
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude": history(day: "2026-07-16", tokens: 10, cost: 1),
                "claude@ab12cd34": history(day: "2026-07-16", tokens: 20, cost: 2),
            ],
            identities: ["claude@ab12cd34": teamKey]
        )
        let remapped = PeerHistoryRemapper.remap(
            documents: [doc],
            localIdentityByCardID: ["claude": maxKey]
        )

        XCTAssertTrue(remapped.histories.contains { $0.cardID == "claude" },
                      "the family total stays on the bare family card")
        XCTAssertFalse(remapped.remoteOnly.contains { $0.family == "claude" && $0.identityKey == maxKey },
                       "the total is never re-attributed to the locally selected account")
    }

    func testRemoteOnlyAccountFeedsTotalSpend() {
        let registry = makeRegistry()
        let dataStore = WidgetDataStore(
            registry: registry,
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("RemoteTotal"),
            providerIdentityKeys: ["claude": maxKey]
        )
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: today, tokens: 1_000_000, cost: 42)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)
        let entry = dataStore.remoteOnlySpend[0]
        let expectedCardID = ProviderAccountID.make(family: "claude", identityKey: "uuid-other|org-x")
        XCTAssertEqual(entry.provider.displayName, expectedCardID, "the slice is named by the account code alone — the source Mac is irrelevant")

        let total = TotalSpendAggregator.total(
            for: .today,
            providers: [entry.provider],
            snapshots: [entry.provider.id: entry.snapshot]
        )
        XCTAssertEqual(total.slices.count, 1)
        XCTAssertEqual(total.slices[0].amountUSD, 42, accuracy: 0.001)
    }

    func testSeveralRemoteOnlyAccountsFromOneDeviceStayTellableApart() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("ManyRemote"),
            providerIdentityKeys: ["claude": maxKey]
        )
        let today = dayKey(Date())
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: [
                "claude@11111111": history(day: today, tokens: 10, cost: 1),
                "claude@22222222": history(day: today, tokens: 20, cost: 2),
            ],
            identities: [
                "claude@11111111": "uuid-a|org-a",
                "claude@22222222": "uuid-b|org-b",
            ]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")

        XCTAssertEqual(dataStore.remoteOnlySpend.count, 2)
        let names = Set(dataStore.remoteOnlySpend.map(\.provider.displayName))
        XCTAssertEqual(names.count, 2, "every remote-only account carries a unique display name")
        for name in names {
            XCTAssertTrue(name.hasPrefix("claude@"), "unexpected slice name: \(name)")
        }
    }

    func testClearingPeersDropsRemoteOnlyEntries() {
        let dataStore = WidgetDataStore(
            registry: makeRegistry(),
            providers: [],
            cache: scratchCache(),
            defaults: makeScratchDefaults("ClearPeers"),
            providerIdentityKeys: ["claude": maxKey]
        )
        let doc = makeDocument(
            deviceName: "Mac mini",
            providers: ["claude@ab12cd34": history(day: dayKey(Date()), tokens: 10, cost: 1)],
            identities: ["claude@ab12cd34": "uuid-other|org-x"]
        )
        dataStore.setPeerHistoryDocuments([doc], ownDeviceID: "this-mac")
        XCTAssertEqual(dataStore.remoteOnlySpend.count, 1)

        dataStore.clearPeerHistoryDocuments()
        XCTAssertTrue(dataStore.remoteOnlySpend.isEmpty, "sync off returns Total Spend to local-only")
    }

    func testRemoteOnlySpendExcludesDisabledFamilyOnPeerArrival() throws {
        let fixture = try makeRemoteSpendFixture(enabledIDs: ["codex"])

        XCTAssertTrue(fixture.layout.hasSpendCapableProvider)
        XCTAssertEqual(fixture.layout.spendCapableProviders.map(\.id), ["codex"])
        XCTAssertEqual(fixture.store.remoteOnlySpend.map(\.provider.id), [fixture.remoteCodexID])
        XCTAssertNil(fixture.store.snapshots["claude"])
        for period in [TotalSpendPeriod.today, .last30] {
            let total = totalSpend(fixture.store, layout: fixture.layout, period: period)
            XCTAssertEqual(total.slices.map(\.id), [fixture.remoteCodexID])
            XCTAssertEqual(total.totalUSD, 7, accuracy: 0.001)
            XCTAssertEqual(total.totalTokens, 700)
        }
    }

    func testRemoteOnlySpendFollowsFamilyToggleWithoutReloadingPeers() throws {
        let fixture = try makeRemoteSpendFixture(enabledIDs: ["claude", "codex"])
        let before = totalSpend(fixture.store, layout: fixture.layout)
        XCTAssertEqual(fixture.store.remoteOnlySpend.count, 3)
        XCTAssertEqual(before.slices.count, 4)
        XCTAssertEqual(before.totalUSD, 65, accuracy: 0.001)
        XCTAssertEqual(before.totalTokens, 6_500)

        fixture.enablement.setEnabled(false, for: "claude")

        let disabled = totalSpend(fixture.store, layout: fixture.layout)
        XCTAssertEqual(fixture.store.remoteOnlySpend.map(\.provider.id), [fixture.remoteCodexID])
        XCTAssertNil(fixture.store.snapshots["claude"])
        XCTAssertEqual(disabled.slices.map(\.id), [fixture.remoteCodexID])
        XCTAssertEqual(disabled.totalUSD, 7, accuracy: 0.001)
        XCTAssertEqual(disabled.totalTokens, 700)

        fixture.enablement.setEnabled(true, for: "claude")

        XCTAssertEqual(fixture.store.remoteOnlySpend.count, 3)
        XCTAssertEqual(totalSpend(fixture.store, layout: fixture.layout), before)
    }

    func testRemoteOnlySpendRemainsWhileAnAdditionalFamilyCardIsEnabled() throws {
        let fixture = try makeRemoteSpendFixture(enabledIDs: ["claude@f15456b0", "codex"])

        XCTAssertFalse(fixture.enablement.isEnabled("claude"))
        XCTAssertTrue(fixture.enablement.isEnabled("claude@f15456b0"))
        XCTAssertEqual(fixture.store.remoteOnlySpend.count, 3)
        XCTAssertNil(fixture.store.snapshots["claude"], "the disabled matching account stays excluded")
        let total = totalSpend(fixture.store, layout: fixture.layout)
        XCTAssertEqual(total.slices.count, 3)
        XCTAssertEqual(total.totalUSD, 54, accuracy: 0.001)
        XCTAssertEqual(total.totalTokens, 5_400)

        fixture.enablement.setEnabled(false, for: "claude@f15456b0")

        let disabled = totalSpend(fixture.store, layout: fixture.layout)
        XCTAssertEqual(fixture.store.remoteOnlySpend.map(\.provider.id), [fixture.remoteCodexID])
        XCTAssertEqual(disabled.slices.map(\.id), [fixture.remoteCodexID])
        XCTAssertEqual(disabled.totalUSD, 7, accuracy: 0.001)
        XCTAssertEqual(disabled.totalTokens, 700)
    }

    // MARK: - Fixtures

    private func makeRemoteSpendFixture(enabledIDs: Set<String>) throws -> (
        store: WidgetDataStore, enablement: ProviderEnablementStore,
        layout: LayoutStore, remoteCodexID: String
    ) {
        let now = Date(timeIntervalSince1970: 1_793_249_200)
        let today = dayKey(now)
        let providers = [
            ClaudeProvider.makeProvider(),
            ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude — Team"),
            CodexProvider.makeProvider(),
        ]
        let descriptors = providers.flatMap { provider in
            [WidgetDescriptor.usageTrend(provider: provider)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")]
                + WidgetDescriptor.spendTiles(provider: provider)
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let defaults = makeScratchDefaults("RemoteEnablement")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(enabledIDs)
        let store = WidgetDataStore(
            registry: registry, providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now }),
            defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) },
            now: { now },
            providerIdentityKeys: ["claude": maxKey, "claude@f15456b0": teamKey]
        )
        enablement.onChange = { [weak store] in store?.providerEnablementDidChange() }
        let layout = LayoutStore(
            registry: registry, defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        let document = UsageHistoryDocument(
            deviceID: "peer", deviceName: "Peer Mac", updatedAt: now,
            providers: [
                "claude": history(day: today, tokens: 1_100, cost: 11),
                "claude@11111111": history(day: today, tokens: 4_200, cost: 42),
                "claude@22222222": history(day: today, tokens: 500, cost: 5),
                "codex@33333333": history(day: today, tokens: 700, cost: 7),
            ],
            identities: [
                "claude": maxKey,
                "claude@11111111": "remote-claude|org-x",
                "codex@33333333": "remote-codex",
            ]
        )
        try document.validate()
        store.setPeerHistoryDocuments([document], ownDeviceID: "this-mac")
        return (
            store, enablement, layout,
            "codex@peer-\(ProviderAccountID.hash8("remote-codex"))"
        )
    }

    private func totalSpend(
        _ store: WidgetDataStore, layout: LayoutStore, period: TotalSpendPeriod = .today
    ) -> TotalSpend {
        var snapshots = store.snapshots
        for entry in store.remoteOnlySpend {
            snapshots[entry.provider.id] = entry.snapshot
        }
        return TotalSpendAggregator.total(
            for: period,
            providers: layout.spendCapableProviders + store.remoteOnlySpend.map(\.provider),
            snapshots: snapshots
        )
    }

    private func makeRegistry() -> WidgetRegistry {
        let claude = ClaudeProvider.makeProvider()
        let extraCard = ClaudeProvider.makeProvider(id: "claude@f15456b0", displayName: "Claude — Team")
        let descriptors = [
            WidgetDescriptor.usageTrend(provider: claude)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
            WidgetDescriptor.usageTrend(provider: extraCard)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test"),
        ]
        return WidgetRegistry(providers: [claude, extraCard], descriptors: descriptors)
    }

    private func scratchCache() -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: makeScratchDefaults("Cache"), storageKey: "snapshots", ttl: 600)
    }

    private func makeScratchDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.PeerIdentity.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func makeDocument(
        deviceName: String = "Peer",
        providers: [String: ProviderUsageHistory],
        identities: [String: String]?
    ) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString,
            deviceName: deviceName,
            updatedAt: Date(),
            providers: providers,
            identities: identities
        )
    }

    private func history(day: String, tokens: Int, cost: Double) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [DailyUsageEntry(date: day, totalTokens: tokens, costUSD: cost)]),
            modelUsage: nil,
            unknownModelsByDay: [:]
        )
    }

    private func snapshot(providerID: String, history: ProviderUsageHistory) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot(
            providerID: providerID,
            displayName: providerID,
            lines: [],
            refreshedAt: Date()
        )
        snapshot.usageHistory = history
        return snapshot
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
