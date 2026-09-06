import XCTest
@testable import OpenUsage

@MainActor
final class ProviderCatalogTests: XCTestCase {
    func testEstablishedProvidersLeadAlphabeticalTail() {
        let names = ProviderCatalog.make().map(\.provider.displayName)

        XCTAssertEqual(Array(names.prefix(3)), ["Claude", "Codex", "Cursor"])
        XCTAssertEqual(Array(names.dropFirst(3)), names.dropFirst(3).sorted())
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderCatalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testCodexSnapshotCardsSlotInAfterTheDefaultCodexCard() {
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")

        let runtimes = ProviderCatalog.make(snapshotCards: [card])

        let ids = runtimes.map(\.provider.id)
        XCTAssertEqual(Array(ids.prefix(4)), ["claude", "codex", "codex@profile-p1", "cursor"])
        let accountRuntime = runtimes.compactMap { $0 as? CodexProvider }.first { $0.provider.id == card.id }
        XCTAssertEqual(accountRuntime?.provider.displayName, "Codex")
        XCTAssertEqual(accountRuntime?.includePiUsage, false)
        let descriptorIDs = accountRuntime?.widgetDescriptors.map(\.id) ?? []
        XCTAssertEqual(
            descriptorIDs.count,
            CodexProvider().widgetDescriptors.count,
            "a snapshot card exposes exactly the default card's metric set"
        )
        for expected in ["session", "weekly", "trend", "resetWatch", "rateLimitResets", "credits", "today"] {
            XCTAssertTrue(
                descriptorIDs.contains("\(card.id).\(expected)"),
                "missing per-card metric \(card.id).\(expected)"
            )
        }
        XCTAssertFalse(descriptorIDs.contains("codex.session"), "metric ids never leak the bare card id")
    }

    func testCodexResetWatchPrecedesRateLimitResets() throws {
        let codex = try XCTUnwrap(
            ProviderCatalog.make()
                .compactMap { $0 as? CodexProvider }
                .first { $0.provider.id == "codex" }
        )
        let descriptorIDs = codex.widgetDescriptors.map(\.id)
        let resetWatchIndex = try XCTUnwrap(descriptorIDs.firstIndex(of: "codex.resetWatch"))
        let rateLimitResetsIndex = try XCTUnwrap(descriptorIDs.firstIndex(of: "codex.rateLimitResets"))

        XCTAssertEqual(resetWatchIndex + 1, rateLimitResetsIndex)
    }

    func testManagedSwitchingPinsTheDefaultCodexCardToTheSharedAuthFile() throws {
        let pinned = ProviderCatalog.make(codexSharedAuthHome: "/Users/x/.codex")
            .compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == "codex" }
        XCTAssertEqual(pinned?.authStore.scope, .home(path: "/Users/x/.codex"))

        let unmanaged = ProviderCatalog.make()
            .compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == "codex" }
        XCTAssertEqual(unmanaged?.authStore.scope, .standard)
    }

    func testManagedSwitchingPinsTheDefaultClaudeCardToTheSharedHome() {
        let pinned = ProviderCatalog.make(claudeManagedSwitchActive: true)
            .compactMap { $0 as? ClaudeProvider }
            .first { $0.provider.id == "claude" }
        XCTAssertEqual(pinned?.authStore.pinsSharedHome, true)
        XCTAssertEqual(pinned?.logUsageScanner.pinsSharedHome, true)
        XCTAssertEqual(pinned?.authStore.allowsDesktopFallback, false)

        let unmanaged = ProviderCatalog.make()
            .compactMap { $0 as? ClaudeProvider }
            .first { $0.provider.id == "claude" }
        XCTAssertEqual(unmanaged?.authStore.pinsSharedHome, false)
        XCTAssertEqual(unmanaged?.logUsageScanner.pinsSharedHome, false)
    }

    func testAnotherClaudeLoginOnThisMacDisablesUnscopedPiUsage() {
        let claudeRuntimes = ProviderCatalog.make(hasUnregisteredClaudeLogins: true)
            .compactMap { $0 as? ClaudeProvider }

        XCTAssertTrue(claudeRuntimes.allSatisfy { !$0.includePiUsage })
        XCTAssertTrue(claudeRuntimes.allSatisfy { !$0.authStore.allowsDesktopFallback })
    }

    func testCustomizeShowsOneRowForAProviderWithMultipleAccounts() {
        let card = AccountUsageSnapshotCard(id: "claude@profile-work", profileID: "work", family: "claude")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")

        XCTAssertEqual(
            layout.customizeProviderRows
                .filter { ProviderAccountID.family(of: $0.id) == "claude" }
                .map(\.id),
            ["claude"]
        )
    }

    func testCodexSnapshotCardsRenderTheirFamilyLayout() {
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")

        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertTrue(layout.isMetricEnabled("\(card.id).weekly"))

        let group = layout.displayGroups.first { $0.provider.id == card.id }
        XCTAssertNotNil(group, "the snapshot card renders its own dashboard group")
        let expandedIDs = group?.expandedWidgets.map(\.descriptorID) ?? []
        XCTAssertTrue(expandedIDs.contains("\(card.id).trend"), "the family's caret split applies to the card")
        XCTAssertTrue(expandedIDs.contains("\(card.id).rateLimitResets"))

        XCTAssertFalse(
            layout.pinnedMetricIDs.contains { ProviderAccountID.isAccountCard($0) },
            "layout settings are stored per provider, never per account card"
        )
    }

    func testAccountCardDiscoveredAfterLaunchSeedsTheLiveLayout() {
        let defaults = makeScratchDefaults()
        let layout = LayoutStore(
            registry: WidgetRegistry.from(ProviderCatalog.make()),
            defaults: defaults,
            storageKey: "layout"
        )
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")
        let updatedRegistry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))

        layout.replaceRegistry(updatedRegistry)

        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertTrue(layout.displayGroups.contains { $0.provider.id == card.id })
        XCTAssertFalse(
            layout.pinnedMetricIDs.contains { $0.hasPrefix("\(card.id).") },
            "an account discovered at runtime must not claim menu-bar space by default"
        )
    }

    func testInactiveDefaultSnapshotSeedsASelectableDashboardGroup() {
        let defaults = makeScratchDefaults()
        let layout = LayoutStore(
            registry: WidgetRegistry.from(ProviderCatalog.make()),
            defaults: defaults,
            storageKey: "layout"
        )
        let card = AccountUsageSnapshotCard(
            id: "claude@profile-claude-default-home",
            profileID: "claude-default-home",
            family: "claude"
        )

        layout.replaceRegistry(WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card])))

        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertTrue(layout.displayGroups.contains { $0.provider.id == card.id })
    }

    func testMenuBarStarsAreSharedByEveryCardOfAProvider() {
        let card = AccountUsageSnapshotCard(id: "claude@profile-work", profileID: "work", family: "claude")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let layout = LayoutStore(
            registry: registry,
            defaults: makeScratchDefaults(),
            storageKey: "layout",
            defaultPinnedMetricIDs: ["claude.session", "claude.weekly", "codex.weekly"]
        )

        // star는 family 설정 — 계정 전환이 pin을 옮길 필요 없이 카드가 그대로 물려받음
        XCTAssertTrue(layout.isPinned("\(card.id).session"))
        XCTAssertTrue(layout.isPinned("\(card.id).weekly"))
        XCTAssertEqual(layout.pinnedCount(forProvider: card.id), 2)

        layout.setPinned(false, for: "\(card.id).weekly")

        XCTAssertFalse(layout.isPinned("claude.weekly"), "unstarring on a card unstars the provider")
        XCTAssertEqual(layout.pinnedMetricIDs, ["claude.session", "codex.weekly"])
    }
}
