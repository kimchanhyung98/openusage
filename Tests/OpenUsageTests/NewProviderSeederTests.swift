import XCTest
@testable import OpenUsage

@MainActor
final class NewProviderSeederTests: XCTestCase {
    func testNewProviderWithCredentialsIsEnabled() async {
        let enablement = seededStore("detect", enabled: ["claude"], known: ["claude", "codex"])
        let providers = [
            probe("claude", hasCredentials: true),
            probe("codex", hasCredentials: true),
            probe("windsurf", hasCredentials: true)
        ]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "windsurf"])
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "windsurf"])
    }

    func testNewProviderWithoutCredentialsStaysOffAndIsNeverReprobed() async {
        let enablement = seededStore("miss", enabled: ["claude"], known: ["claude"])
        let newcomer = probe("windsurf", hasCredentials: false)

        let firstRun = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), newcomer], enablement: enablement
        )
        await firstRun?.value

        XCTAssertFalse(enablement.isEnabled("windsurf"))
        XCTAssertEqual(newcomer.probeCount, 1)

        // 다음 launch: windsurf는 이미 known — task·재probe 없음, 활성화는 사용자 몫
        let secondRun = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), newcomer], enablement: enablement
        )
        XCTAssertNil(secondRun)
        XCTAssertEqual(newcomer.probeCount, 1)
    }

    func testKnownButDisabledProviderIsNeverProbedOrReenabled() async {
        // 사용자가 끈 grok은 credential이 있어도 자동 재활성화 금지
        let enablement = seededStore("user-off", enabled: ["claude"], known: ["claude", "grok"])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertNil(task, "nothing new to detect")
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testLegacyModeStoreIsUntouched() {
        // legacy disabled-list install은 새 provider가 기본 on — seeder는 mode 전환·쓰기 금지
        let enablement = ProviderEnablementStore(defaults: makeDefaults("legacy"))

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("windsurf", hasCredentials: true)], enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs)
        XCTAssertTrue(enablement.knownIDs.isEmpty)
    }

    func testEmptyKnownSetIsBaselinedWithoutProbing() {
        // known set 없는 enabled-list store — "new"와 "사용자 off" 구분 불가라 baseline만 기록
        let enablement = seededStore("baseline", enabled: ["claude"], known: [])
        let grok = probe("grok", hasCredentials: true)

        let task = NewProviderSeeder.reconcileIfNeeded(
            providers: [probe("claude", hasCredentials: true), grok], enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.knownIDs, ["claude", "grok"])
        XCTAssertFalse(enablement.isEnabled("grok"))
        XCTAssertEqual(grok.probeCount, 0)
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = seededStore("toggle-wins", enabled: ["claude"], known: ["claude"])
        var enableCallbacks: [String] = []
        enablement.onProviderEnabled = { enableCallbacks.append($0) }
        let providers = [probe("claude", hasCredentials: true), probe("windsurf", hasCredentials: true)]

        let task = NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement)
        // probe 진행 중 사용자가 직접 on — seeder는 toggle 재설정 금지
        enablement.setEnabled(true, for: "windsurf")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "windsurf"])
        XCTAssertEqual(enableCallbacks, ["windsurf"], "the seeder must not fire a second enable")
    }

    // MARK: - Helpers

    private func seededStore(_ name: String, enabled: Set<String>, known: Set<String>) -> ProviderEnablementStore {
        let store = ProviderEnablementStore(defaults: makeDefaults(name))
        store.seedEnabledProviders(enabled)
        store.registerKnownProviders(known)
        return store
    }

    private func probe(_ id: String, hasCredentials: Bool) -> ProbeCountingProvider {
        ProbeCountingProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.NewProviderSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class ProbeCountingProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool
    private(set) var probeCount = 0

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool {
        probeCount += 1
        return hasCredentials
    }
}
