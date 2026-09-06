import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitSettingsStoreTests: XCTestCase {
    func testWindowLabelsMatchSettingsCopy() {
        XCTAssertEqual(SoftLimitWindow.fiveHours.label, "5 Hours")
        XCTAssertEqual(SoftLimitWindow.weekly.label, "Weekly")
    }

    func testDefaultsAreOffWeeklyAndNinetyFivePercent() {
        let defaults = makeDefaults("defaults")

        let store = SoftLimitSettingsStore(defaults: defaults)

        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.window, .weekly)
        XCTAssertEqual(store.thresholdPercent, 95)
    }

    func testChoicesPersistAcrossStoreInstances() {
        let defaults = makeDefaults("persistence")
        let store = SoftLimitSettingsStore(defaults: defaults)

        store.enabled = true
        store.window = .fiveHours
        store.thresholdPercent = 90

        let reloaded = SoftLimitSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.window, .fiveHours)
        XCTAssertEqual(reloaded.thresholdPercent, 90)
    }

    func testThresholdAssignmentsStayWithinNinetyToNinetyFivePercent() {
        let store = SoftLimitSettingsStore(defaults: makeDefaults("assignment-range"))

        store.thresholdPercent = 89
        XCTAssertEqual(store.thresholdPercent, 90)

        store.thresholdPercent = 96
        XCTAssertEqual(store.thresholdPercent, 95)
    }

    func testPersistedThresholdIsClampedAndMalformedValuesUseDefault() {
        let low = makeDefaults("persisted-low")
        low.set(89, forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: low).thresholdPercent, 90)

        let high = makeDefaults("persisted-high")
        high.set(96, forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: high).thresholdPercent, 95)

        let malformed = makeDefaults("persisted-malformed")
        malformed.set("95", forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: malformed).thresholdPercent, 95)
    }

    func testUnknownPersistedWindowUsesWeeklyDefault() {
        let defaults = makeDefaults("unknown-window")
        defaults.set("monthly", forKey: "openusage.softLimit.window.v1")

        XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults).window, .weekly)
    }

    func testUsedFractionRequiresEnabledMatchingWindow() {
        let store = SoftLimitSettingsStore(defaults: makeDefaults("window-policy"))
        XCTAssertNil(store.usedFraction(for: .weekly, periodDurationMs: MetricPeriod.weekMs))

        store.enabled = true
        XCTAssertEqual(
            store.usedFraction(for: .weekly, periodDurationMs: MetricPeriod.weekMs) ?? -1,
            0.95,
            accuracy: 0.0001
        )
        XCTAssertNil(store.usedFraction(for: .weekly, periodDurationMs: 3 * 24 * 60 * 60 * 1000))
        XCTAssertNil(store.usedFraction(for: .weekly, periodDurationMs: nil))
        XCTAssertNil(store.usedFraction(for: .fiveHours, periodDurationMs: MetricPeriod.sessionMs))
        XCTAssertNil(store.usedFraction(for: nil, periodDurationMs: MetricPeriod.weekMs))

        store.window = .fiveHours
        store.thresholdPercent = 90
        XCTAssertEqual(
            store.usedFraction(for: .fiveHours, periodDurationMs: MetricPeriod.sessionMs) ?? -1,
            0.90,
            accuracy: 0.0001
        )
        XCTAssertNil(store.usedFraction(for: .fiveHours, periodDurationMs: 3 * 60 * 60 * 1000))
        XCTAssertNil(store.usedFraction(for: .weekly, periodDurationMs: MetricPeriod.weekMs))
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.SoftLimit.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
