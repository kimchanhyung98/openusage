import XCTest
@testable import OpenUsage

@MainActor
final class ProviderEnablementStoreTests: XCTestCase {
    func testEmptySuiteEnablesEverything() {
        let store = ProviderEnablementStore(defaults: makeDefaults("empty"))

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
    }

    func testDisablingPersistsAcrossInstances() {
        let defaults = makeDefaults("persist")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "codex")

        XCTAssertFalse(store.isEnabled("codex"))
        XCTAssertTrue(store.isEnabled("claude"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.disabledIDs, ["codex"])
        XCTAssertFalse(reloaded.isEnabled("codex"))
        XCTAssertTrue(reloaded.isEnabled("claude"))
    }

    func testReEnablingClearsDisabledStateAndPersists() {
        let defaults = makeDefaults("re-enable")
        let store = ProviderEnablementStore(defaults: defaults)

        store.setEnabled(false, for: "grok")
        store.setEnabled(true, for: "grok")

        XCTAssertTrue(store.disabledIDs.isEmpty)
        XCTAssertTrue(store.isEnabled("grok"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(reloaded.disabledIDs.isEmpty)
        XCTAssertTrue(reloaded.isEnabled("grok"))
    }

    // MARK: - Early-refresh signal

    func testRealChangePostsDidChangeNotification() {
        let store = ProviderEnablementStore(defaults: makeDefaults("notify-change"))
        let posted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)

        store.setEnabled(false, for: "codex")

        wait(for: [posted], timeout: 1)
    }

    func testNoOpToggleDoesNotPostDidChangeNotification() {
        // refresh loop가 이 notification으로 wake — 무의미한 toggle은 wake·재probe 금지
        let store = ProviderEnablementStore(defaults: makeDefaults("notify-noop"))
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.setEnabled(true, for: "codex")

        wait(for: [notPosted], timeout: 0.2)
    }

    func testOnProviderEnabledFiresOnEnableOnly() {
        // failure backoff clear 용도 — 실제 enable에만 발화
        let store = ProviderEnablementStore(defaults: makeDefaults("on-enable"))
        var enabledIDs: [String] = []
        store.onProviderEnabled = { enabledIDs.append($0) }

        store.setEnabled(false, for: "codex")
        store.setEnabled(true, for: "codex")
        store.setEnabled(true, for: "codex")

        XCTAssertEqual(enabledIDs, ["codex"])
    }

    // MARK: - Enabled-list mode (fresh installs)

    func testSeedingSwitchesToEnabledListMode() {
        let defaults = makeDefaults("seed")
        let store = ProviderEnablementStore(defaults: defaults)

        store.seedEnabledProviders(["claude", "codex"])

        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("codex"))
        XCTAssertFalse(store.isEnabled("grok"))
        // enabled-list mode 핵심 성질 — 이후 추가된 provider는 기본 OFF
        XCTAssertFalse(store.isEnabled("a-provider-that-ships-next-year"))

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.enabledIDs, ["claude", "codex"])
        XCTAssertTrue(reloaded.isEnabled("claude"))
        XCTAssertFalse(reloaded.isEnabled("grok"))
    }

    func testTogglesPersistInEnabledListMode() {
        let defaults = makeDefaults("enabled-toggles")
        let store = ProviderEnablementStore(defaults: defaults)
        store.seedEnabledProviders(["claude"])

        store.setEnabled(true, for: "grok")
        store.setEnabled(false, for: "claude")

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.enabledIDs, ["grok"])
        XCTAssertTrue(reloaded.isEnabled("grok"))
        XCTAssertFalse(reloaded.isEnabled("claude"))
    }

    func testReseedFiresOnProviderEnabledForNewlyOnOnly() {
        let store = ProviderEnablementStore(defaults: makeDefaults("reseed-enable"))
        store.seedEnabledProviders(["claude", "codex"])
        var enabledIDs: [String] = []
        store.onProviderEnabled = { enabledIDs.append($0) }

        // detection pass가 fallback 대체 — codex는 유지(callback 없음), grok만 on
        store.seedEnabledProviders(["codex", "grok"])

        XCTAssertEqual(enabledIDs, ["grok"])
    }

    func testNoOpReseedDoesNotNotify() {
        let store = ProviderEnablementStore(defaults: makeDefaults("reseed-noop"))
        store.seedEnabledProviders(["claude"])
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.seedEnabledProviders(["claude"])

        wait(for: [notPosted], timeout: 0.2)
    }

    func testLegacyModeIgnoresEnabledListUntilSeeded() {
        // 기존 설치본(disabled-list mode)은 semantics 유지 — enabled key 부재 시 disabled 외 전부 on
        let defaults = makeDefaults("legacy-untouched")
        defaults.set(["devin"], forKey: "openusage.disabledProviders.v1")
        let store = ProviderEnablementStore(defaults: defaults)

        XCTAssertNil(store.enabledIDs)
        XCTAssertFalse(store.isEnabled("devin"))
        XCTAssertTrue(store.isEnabled("claude"))
        XCTAssertTrue(store.isEnabled("a-provider-that-ships-next-year"))
    }

    // MARK: - Known-provider set

    func testRegisterKnownProvidersReturnsNewOnesAndPersists() {
        let defaults = makeDefaults("known")
        let store = ProviderEnablementStore(defaults: defaults)
        XCTAssertTrue(store.knownIDs.isEmpty)

        XCTAssertEqual(store.registerKnownProviders(["claude", "codex"]), ["claude", "codex"])
        XCTAssertEqual(store.registerKnownProviders(["claude", "grok"]), ["grok"], "only never-seen IDs")
        XCTAssertEqual(store.registerKnownProviders(["claude"]), [], "no-op re-registration")

        let reloaded = ProviderEnablementStore(defaults: defaults)
        XCTAssertEqual(reloaded.knownIDs, ["claude", "codex", "grok"])
    }

    func testRegisterKnownProvidersDoesNotTouchEnablement() {
        // 단순 기록 — toggle 변경·refresh loop wake 금지
        let store = ProviderEnablementStore(defaults: makeDefaults("known-pure"))
        store.seedEnabledProviders(["claude"])
        let notPosted = XCTNSNotificationExpectation(name: ProviderEnablementStore.didChangeNotification)
        notPosted.isInverted = true

        store.registerKnownProviders(["claude", "grok"])

        XCTAssertEqual(store.enabledIDs, ["claude"])
        XCTAssertFalse(store.isEnabled("grok"))
        wait(for: [notPosted], timeout: 0.2)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.Enablement.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
