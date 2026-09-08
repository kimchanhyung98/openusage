import XCTest
@testable import OpenUsage

@MainActor
final class MenuBarPinTests: XCTestCase {
    func testNoPinsByDefault() {
        let store = makeStore("default")
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
        XCTAssertTrue(store.pinnedGroups.isEmpty)
        XCTAssertEqual(store.menuBarStyle, .bars)
    }

    func testPinUnpinPersistsAcrossReload() {
        let defaults = makeDefaults("persist")
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")

        store.setPinned(true, for: "a.m1")
        XCTAssertTrue(store.isPinned("a.m1"))

        let reloaded = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.isPinned("a.m1"))

        reloaded.setPinned(false, for: "a.m1")
        let reloadedAgain = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloadedAgain.isPinned("a.m1"))
    }

    func testPerProviderCapBlocksThirdPin() {
        let store = makeStore("perProvider")
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")

        XCTAssertFalse(store.canPin("a.m3"))
        store.setPinned(true, for: "a.m3")
        XCTAssertFalse(store.isPinned("a.m3"))
        XCTAssertEqual(store.pinnedCount(forProvider: "a"), 2)

        // 이미 pin된 id는 unpin 토글이 가능하도록 pinnable 유지
        XCTAssertTrue(store.canPin("a.m1"))
    }

    func testEachProviderCanPinUpToTwo() {
        let store = makeStore("manyProviders")
        for provider in ["a", "b", "c", "d"] {
            store.setPinned(true, for: "\(provider).m1")
            store.setPinned(true, for: "\(provider).m2")
            XCTAssertFalse(store.canPin("\(provider).m3"))
        }
        XCTAssertEqual(store.pinnedMetricIDs.count, 8)
    }

    func testPinDenialReasonsAndFooterNotice() {
        let store = makeStore("denial")
        XCTAssertNil(store.pinDenialReason("a.m1"))

        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")
        XCTAssertEqual(store.pinDenialReason("a.m3"), "Up to 2 stars per provider")
        XCTAssertNil(store.pinDenialReason("b.m1"))

        XCTAssertNil(store.pinDenialReason("b.m1"))

        // 거부 클릭은 footer notice 표시 + 매번 shake trigger 증가 — 동일 문구에서도 재shake
        XCTAssertNil(store.pinLimitNotice)
        XCTAssertEqual(store.pinNoticeShakeTrigger, 0)
        store.notePinDenied("a.m3")
        XCTAssertEqual(store.pinLimitNotice, "Up to 2 stars per provider")
        XCTAssertEqual(store.pinNoticeShakeTrigger, 1)
        store.notePinDenied("a.m3")
        XCTAssertEqual(store.pinNoticeShakeTrigger, 2)
    }

    func testUnpinFreesAProviderSlot() {
        let store = makeStore("freeSlot")
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "a.m2")
        XCTAssertFalse(store.canPin("a.m3"))

        store.setPinned(false, for: "a.m1")
        XCTAssertTrue(store.canPin("a.m3"))
    }

    func testPinnedGroupsFollowCustomizeOrder() {
        let store = makeStore("order")
        // 순서 뒤섞어 pin — 결과는 provider 순서(a→b)와 metric 순서(m1→m2)
        store.setPinned(true, for: "b.m2")
        store.setPinned(true, for: "a.m2")
        store.setPinned(true, for: "a.m1")

        XCTAssertEqual(store.pinnedGroups.flatMap { $0.metrics.map(\.id) }, ["a.m1", "a.m2", "b.m2"])
        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["a", "b"])
    }

    func testRefreshDescriptorsIncludeDisabledMetricPinnedOnlyForMenuBar() {
        let store = makeStore("refreshDescriptors")
        XCTAssertTrue(store.orderedRenderedDescriptors().isEmpty)

        store.setPinned(true, for: "a.m1")

        XCTAssertEqual(store.orderedRefreshDescriptors().map(\.id), ["a.m1"])
        store.setMetricEnabled("a.m1", true)
        XCTAssertEqual(store.orderedRefreshDescriptors().map(\.id), ["a.m1"])
        store.setPinned(false, for: "a.m1")
        XCTAssertEqual(store.orderedRefreshDescriptors().map(\.id), ["a.m1"])
        store.setMetricEnabled("a.m1", false)
        XCTAssertTrue(store.orderedRefreshDescriptors().isEmpty)
    }

    func testDisabledProviderPinsExcludedFromGroupsButKept() {
        let store = LayoutStore(
            registry: makeRegistry(),
            defaults: makeDefaults("disabled"),
            storageKey: "layout",
            isProviderEnabled: { $0 != "a" }
        )
        store.setPinned(true, for: "a.m1")
        store.setPinned(true, for: "b.m1")

        XCTAssertEqual(store.pinnedGroups.map(\.provider.id), ["b"])
        XCTAssertEqual(store.orderedRefreshDescriptors().map(\.id), ["b.m1"])
        XCTAssertTrue(store.isPinned("a.m1"))  // 숨겨진 동안에도 membership 유지
    }

    func testResetToDefaultClearsPins() {
        let store = makeStore("reset")
        store.setPinned(true, for: "a.m1")
        store.resetToDefault()
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty)
    }

    func testMenuBarStylePersists() {
        let defaults = makeDefaults("style")
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        store.menuBarStyle = .bars

        let reloaded = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")
        XCTAssertEqual(reloaded.menuBarStyle, .bars)
    }

    func testInvalidPinnedIDsDroppedOnLoad() {
        let defaults = makeDefaults("invalid")
        defaults.set(["a.m1", "ghost.metric"], forKey: "layout.menuBarPins")
        let store = LayoutStore(registry: makeRegistry(), defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isPinned("a.m1"))
        XCTAssertFalse(store.isPinned("ghost.metric"))
    }

    // MARK: - Fixtures

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: makeRegistry(), defaults: makeDefaults(name), storageKey: "layout")
    }

    /// provider 4개(a~d) × percent metric 3개(m1~m3), registry 순서 고정
    private func makeRegistry() -> WidgetRegistry {
        let providers = ["a", "b", "c", "d"].map { id in
            Provider(id: id, displayName: id.uppercased(), icon: .providerMark("cursor"))
        }
        let descriptors = providers.flatMap { provider in
            (1...3).map { n in metric(provider, id: "\(provider.id).m\(n)", label: "M\(n)") }
        }
        return WidgetRegistry(providers: providers, descriptors: descriptors)
    }

    private func metric(_ provider: Provider, id: String, label: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: label,
            sample: WidgetData(
                title: label,
                icon: provider.icon,
                kind: .percent,
                used: 10,
                limit: 100
            )
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.MenuBarPin.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
