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

    /// An inactive Codex profile's snapshot becomes an ordinary runtime right after the default
    /// Codex card: per-card provider id and a metric set whose ids derive from the card id — while
    /// the default card stays first and unchanged.
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
        for expected in ["session", "weekly", "trend", "rateLimitResets", "credits", "today"] {
            XCTAssertTrue(
                descriptorIDs.contains("\(card.id).\(expected)"),
                "missing per-card metric \(card.id).\(expected)"
            )
        }
        XCTAssertFalse(descriptorIDs.contains("codex.session"), "metric ids never leak the bare card id")
    }

    /// Managed switching pins the default Codex card to the shared `auth.json` the switch
    /// transaction owns; without it the historical candidate scan stays in place.
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

    func testSplitClaudeCardsDisableUnscopedPiUsage() {
        let card = ClaudeAccountCard(
            id: "claude@ab12cd34",
            displayName: "Claude — Work",
            configDirPath: "/tmp/claude-work",
            keychainLiteral: "claude-work"
        )

        let claudeRuntimes = ProviderCatalog.make(claudeCards: [card]).compactMap { $0 as? ClaudeProvider }

        XCTAssertTrue(claudeRuntimes.allSatisfy { !$0.includePiUsage })
    }

    func testCustomizeShowsOneRowForAProviderWithMultipleAccounts() {
        let card = ClaudeAccountCard(
            id: "claude@ab12cd34",
            displayName: "Claude — Work",
            configDirPath: "/tmp/claude-work",
            keychainLiteral: "claude-work"
        )
        let registry = WidgetRegistry.from(ProviderCatalog.make(claudeCards: [card]))
        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")

        XCTAssertEqual(
            layout.customizeProviderRows
                .filter { ProviderAccountID.family(of: $0.id) == "claude" }
                .map(\.id),
            ["claude"]
        )
    }

    /// Layout seeding end to end: `DefaultLayout.translatedForAccountCards` re-prefixes the codex
    /// family defaults onto the snapshot card (and the caret split), every translated id exists in
    /// the registry, and pins stay untranslated.
    func testCodexSnapshotCardsSeedTheirFamilyDefaultLayout() {
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let providerIDs = registry.providers.map(\.id)

        let translatedMetrics = DefaultLayout.translatedForAccountCards(DefaultLayout.metricIDs, providerIDs: providerIDs)
        XCTAssertTrue(translatedMetrics.contains("\(card.id).session"))
        XCTAssertTrue(translatedMetrics.contains("\(card.id).weekly"))
        let translatedExpanded = DefaultLayout.translatedForAccountCards(DefaultLayout.expandedMetricIDs, providerIDs: providerIDs)
        XCTAssertTrue(translatedExpanded.contains("\(card.id).trend"))
        XCTAssertTrue(translatedExpanded.contains("\(card.id).rateLimitResets"))
        for id in translatedMetrics + translatedExpanded where id.hasPrefix("\(card.id).") {
            XCTAssertNotNil(registry.descriptor(id: id), "translated id \(id) must exist in the registry")
        }

        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")
        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertFalse(
            layout.pinnedMetricIDs.contains { ProviderAccountID.isAccountCard($0) },
            "an extra account never claims menu-bar space by default"
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

    func testSwitchingAnAccountRetargetsOnlyThatFamilysMenuBarPins() {
        let card = ClaudeAccountCard(
            id: "claude@ab12cd34",
            displayName: "Claude — Work",
            configDirPath: "/tmp/claude-work",
            keychainLiteral: "claude-work"
        )
        let registry = WidgetRegistry.from(ProviderCatalog.make(claudeCards: [card]))
        let layout = LayoutStore(
            registry: registry,
            defaults: makeScratchDefaults(),
            storageKey: "layout",
            defaultPinnedMetricIDs: ["claude.session", "claude.weekly", "codex.weekly"]
        )

        layout.retargetMenuBarPins(for: "claude", to: card.id)

        XCTAssertEqual(
            layout.pinnedMetricIDs,
            ["\(card.id).session", "\(card.id).weekly", "codex.weekly"]
        )
    }
}
