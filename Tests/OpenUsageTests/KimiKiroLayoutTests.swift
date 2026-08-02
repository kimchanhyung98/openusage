import XCTest
@testable import OpenUsage

@MainActor
final class KimiKiroLayoutTests: XCTestCase {
    func testFreshDefaultsMatchOwnerApprovedPlacement() {
        let suiteName = "OpenUsageTests.KimiKiroLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = WidgetRegistry.from([KimiProvider(), KiroProvider()])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "kimi.session", "kimi.weekly", "kiro.credits"
        ])
        XCTAssertEqual(store.pinnedMetricIDs, [
            "kimi.weekly", "kiro.credits"
        ])

        let kimi = store.customizeGroups.first { $0.provider.id == "kimi" }
        XCTAssertEqual(kimi?.alwaysShownMetrics.map(\.id), ["kimi.session", "kimi.weekly"])
        XCTAssertTrue(kimi?.expandedMetrics.isEmpty == true)

        let kiro = store.customizeGroups.first { $0.provider.id == "kiro" }
        XCTAssertEqual(kiro?.alwaysShownMetrics.map(\.id), ["kiro.credits"])
        XCTAssertTrue(kiro?.expandedMetrics.isEmpty == true)
    }
}
