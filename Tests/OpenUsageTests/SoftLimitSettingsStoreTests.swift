import XCTest
@testable import OpenUsage

@MainActor
final class SoftLimitSettingsStoreTests: XCTestCase {
    func testWindowLabelsMatchSettingsCopy() {
        XCTAssertEqual(SoftLimitWindow.fiveHours.label, "5 Hours")
        XCTAssertEqual(SoftLimitWindow.weekly.label, "Weekly")
    }

    func testDefaultsAreOffWeeklyAndNinetyPercent() {
        let defaults = makeDefaults("defaults")

        let store = SoftLimitSettingsStore(defaults: defaults)

        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.window, .weekly)
        XCTAssertEqual(store.thresholdPercent, 90)
        store.enabled = true
        XCTAssertEqual(store.thresholdPercent, 90)
    }

    func testChoicesPersistAcrossStoreInstances() {
        let defaults = makeDefaults("persistence")
        let store = SoftLimitSettingsStore(defaults: defaults)

        store.enabled = true
        store.window = .fiveHours
        store.thresholdPercent = 75

        let reloaded = SoftLimitSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.window, .fiveHours)
        XCTAssertEqual(reloaded.thresholdPercent, 75)
        reloaded.enabled = false
        reloaded.enabled = true
        XCTAssertEqual(reloaded.thresholdPercent, 75)
    }

    func testLegacyGuideEnablementDoesNotAuthorizeCancellation() {
        let defaults = makeDefaults("legacy-guide")
        defaults.set(true, forKey: "openusage.softLimit.enabled.v1")
        defaults.set(94, forKey: "openusage.softLimit.thresholdPercent.v1")
        defaults.set("fiveHours", forKey: "openusage.softLimit.window.v1")

        let store = SoftLimitSettingsStore(defaults: defaults)

        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.thresholdPercent, 94)
        XCTAssertEqual(store.window, .fiveHours)
        XCTAssertTrue(defaults.bool(forKey: "openusage.softLimit.enabled.v1"))
        store.enabled = true
        XCTAssertTrue(SoftLimitSettingsStore(defaults: defaults).enabled)
    }

    func testThresholdAssignmentsSupportTheFullPercentageRange() {
        let store = SoftLimitSettingsStore(defaults: makeDefaults("assignment-range"))

        for percent in [1, 50, 75, 89, 90, 95, 96, 100] {
            store.thresholdPercent = percent
            XCTAssertEqual(store.thresholdPercent, percent)
        }

        store.thresholdPercent = 0
        XCTAssertEqual(store.thresholdPercent, 1)
        store.thresholdPercent = 101
        XCTAssertEqual(store.thresholdPercent, 100)
    }

    func testPersistedThresholdIsClampedAndMalformedValuesUseDefault() {
        let low = makeDefaults("persisted-low")
        low.set(0, forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: low).thresholdPercent, 1)

        let high = makeDefaults("persisted-high")
        high.set(101, forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: high).thresholdPercent, 100)

        let malformed = makeDefaults("persisted-malformed")
        malformed.set("95", forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: malformed).thresholdPercent, 90)
    }

    func testExistingThresholdSurvivesFirstEnableWithTheNewDefault() {
        let defaults = makeDefaults("existing-threshold")
        defaults.set(95, forKey: "openusage.softLimit.thresholdPercent.v1")
        let store = SoftLimitSettingsStore(defaults: defaults)

        XCTAssertFalse(store.enabled)
        store.enabled = true
        XCTAssertEqual(store.thresholdPercent, 95)
    }

    func testDirectInputAcceptsAndPersistsWholePercentages() {
        let defaults = makeDefaults("direct-input")
        let store = SoftLimitSettingsStore(defaults: defaults)

        for (text, percent) in [("1", 1), ("50", 50), ("75", 75), ("96", 96), ("100", 100), (" 89\n", 89)] {
            XCTAssertTrue(store.setThreshold(from: text))
            XCTAssertEqual(store.thresholdPercent, percent)
            XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults).thresholdPercent, percent)
        }
    }

    func testInvalidDirectInputPreservesTheLastSavedThreshold() {
        let defaults = makeDefaults("invalid-input")
        let store = SoftLimitSettingsStore(defaults: defaults)
        XCTAssertTrue(store.setThreshold(from: "75"))

        for text in ["", " ", "word", "90%", "90.5", "-1", "0", "101", "1e2", "999999999999999999999999"] {
            XCTAssertFalse(store.setThreshold(from: text), text)
            XCTAssertEqual(store.thresholdPercent, 75, text)
            XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults).thresholdPercent, 75, text)
        }
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
            0.90,
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
