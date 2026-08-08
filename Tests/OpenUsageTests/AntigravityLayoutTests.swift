import XCTest
@testable import OpenUsage

/// `MockData`에 Antigravity 픽스처가 없어 실제 provider registry 사용
@MainActor
final class AntigravityLayoutTests: XCTestCase {

    func testFreshDefaultsSeedFourMetricsTwoPinsAndClaudePairSecondary() {
        let store = makeStore("FreshDefaults")

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly"
        ])

        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])

        let group = store.customizeGroups.first { $0.provider.id == "antigravity" }
        XCTAssertEqual(group?.alwaysShownMetrics.map(\.id), ["antigravity.geminiPro", "antigravity.geminiWeekly"])
        XCTAssertEqual(group?.expandedMetrics.map(\.id), ["antigravity.claude", "antigravity.claudeWeekly"])
    }

    func testExistingUserLayoutAutoSeedsWeeklyMetricsBelowCaretForClaudePool() {
        // weekly metric 출시 전 layout: 마이그레이션 baseline에 Antigravity 부재 → `seedNewDefaultMetrics`가 1회 자동 enable
        let defaults = makeDefaults("SeedWeeklies")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.claudeWeekly"))
        XCTAssertTrue(store.expandedMetricIDs.contains("antigravity.claudeWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.geminiWeekly"))
        XCTAssertFalse(store.expandedMetricIDs.contains("antigravity.claude"),
                       "a metric the user already lived with is never silently tucked away")
    }

    func testSavedGeminiFlashStateStaysInvisibleWhileItsTombstonesAreRetained() {
        // `antigravity.geminiFlash`는 폐기 — UI에서 제외되나, 일시 부재 account card일 수도 있어 저장 상태는 tombstone으로 유지
        let defaults = makeDefaults("FlashFilter")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.geminiFlash"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)
        defaults.set(["antigravity.geminiPro", "antigravity.geminiFlash"], forKey: "layout.menuBarPins")
        saveStored(
            ["antigravity": ["antigravity.geminiFlash", "antigravity.geminiPro", "antigravity.claude"]],
            forKey: "layout.metricOrderByProvider", in: defaults
        )

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiFlash"))
        XCTAssertFalse(store.orderedSupportedMetrics(for: "antigravity").map(\.id).contains("antigravity.geminiFlash"))
        XCTAssertFalse(store.isPinned("antigravity.geminiFlash"), "the dead pin stays invisible")
        XCTAssertTrue(
            store.pinnedMetricIDs.contains("antigravity.geminiFlash"),
            "…but its tombstone is retained for a possible return"
        )
        XCTAssertTrue(store.isPinned("antigravity.geminiPro"))
        XCTAssertFalse(store.isPinned("antigravity.geminiWeekly"), "an existing pin set gains no new defaults")
    }

    func testAbsentPinsKeyAdoptsGeminiWeeklyPinOnUpgrade() {
        // pins 키 부재 시 현재 기본값에서 재도출, init은 pin을 저장하지 않음 → 기존 사용자도 Gemini Weekly pin 획득
        let defaults = makeDefaults("PinsAbsent")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.geminiPro", "antigravity.geminiWeekly"])
    }

    func testSavedPinsKeyIsRespectedExactly() {
        let defaults = makeDefaults("PinsPresent")
        saveStored([PlacedWidget(descriptorID: "antigravity.geminiPro")], forKey: "layout", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.menuBarPins")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.pinnedMetricIDs, ["antigravity.claude"],
                       "a user-saved pin set must not gain the new default pins")
    }

    // MARK: - Fixtures

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .antigravityOnly, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.AntigravityLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// Antigravity provider만 담은 registry — `DefaultLayout` seed가 4개 metric으로 좁혀짐
    @MainActor
    static var antigravityOnly: WidgetRegistry { .from([AntigravityProvider()]) }
}
