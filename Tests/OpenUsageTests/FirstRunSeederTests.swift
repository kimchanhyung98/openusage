import XCTest
@testable import OpenUsage

@MainActor
final class FirstRunSeederTests: XCTestCase {
    func testFreshInstallSeedsFallbackSynchronouslyThenDetectedSet() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("detect"))
        let onboarding = OnboardingStore(defaults: makeDefaults("detect-onboarding"))
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("kimi", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )

        // probe 완료 전: fallback set 동기 반영 — 전체 provider 노출 방지
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "kimi"])
        XCTAssertTrue(onboarding.isCustomizeHintPending)
        // 현재 출시 provider 전부 "seen" baseline 처리 — `NewProviderSeeder`는 이후 릴리스 추가분만 probe
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "cursor", "grok", "kimi"])

        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testNothingDetectedKeepsFallback() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("none"))
        let onboarding = OnboardingStore(defaults: makeDefaults("none-onboarding"))
        let providers = ["claude", "codex", "kimi", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "kimi"])
    }

    func testExistingInstallIsNeverSeeded() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("existing"))
        let onboarding = OnboardingStore(defaults: makeDefaults("existing-onboarding"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs, "an existing install keeps legacy all-on semantics")
        XCTAssertTrue(enablement.isEnabled("grok"))
        XCTAssertFalse(onboarding.isCustomizeHintPending, "existing installs never see the hint card")
    }

    func testAlreadySeededStoreIsNotReseeded() {
        // unbundled `swift run`은 매 launch fresh 판정 — enabled-list guard로 재seed 방지
        let defaults = makeDefaults("idempotent")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["grok"])
        let onboarding = OnboardingStore(defaults: makeDefaults("idempotent-onboarding"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement, onboarding: onboarding
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("toggle-wins"))
        let onboarding = OnboardingStore(defaults: makeDefaults("toggle-wins-onboarding"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("kimi", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        // probe 진행 중 사용자 toggle — 사용자 선택 우선
        enablement.setEnabled(false, for: "codex")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "kimi"])
    }

    // MARK: - Reset All reseed

    func testReseedOverwritesCurrentChoicesWithDetectedSet() async {
        // Reset All은 재검지 후 설치된 set으로 교체 — credential 없는 기존 활성 provider도 off
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed"))
        enablement.seedEnabledProviders(["codex", "grok"])
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("kimi", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)

        // fallback으로 동기 전환 — dashboard에 reset 즉시 반영
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "kimi"])

        await task.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testReseedKeepsFallbackWhenNothingDetected() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-none"))
        enablement.seedEnabledProviders(["grok"])
        let providers = ["claude", "codex", "kimi", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex", "kimi"])
    }

    func testReseedUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-toggle"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("kimi", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        // probe 진행 중 사용자 toggle — 사용자 선택 우선
        enablement.setEnabled(false, for: "codex")
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "kimi"])
    }

    // MARK: - Concurrent detection

    func testDetectLocalProvidersProbesConcurrently() async {
        // 순차 probe 회귀 방지 — gated stub은 모든 probe가 동시에 시작해야만 credential 보고
        let ids = ["claude", "codex", "cursor", "grok"]
        let gate = ProbeGate(expected: ids.count)
        let providers = ids.map { GatedCredentialProvider(id: $0, gate: gate) }

        let detected = await FirstRunSeeder.detectLocalProviders(providers)

        XCTAssertEqual(detected, Set(ids), "all probes must be in flight at once, not one after another")
    }

    // MARK: - OnboardingStore persistence

    func testCustomizeHintFlagPersistsAcrossInstances() {
        let defaults = makeDefaults("hint-persist")
        let store = OnboardingStore(defaults: defaults)
        XCTAssertFalse(store.isCustomizeHintPending)

        store.markCustomizeHintPending()
        XCTAssertTrue(OnboardingStore(defaults: defaults).isCustomizeHintPending)

        store.dismissCustomizeHint()
        XCTAssertFalse(store.isCustomizeHintPending)
        XCTAssertFalse(OnboardingStore(defaults: defaults).isCustomizeHintPending)
    }

    // MARK: - Helpers

    private func stub(_ id: String, hasCredentials: Bool) -> CredentialStubProvider {
        CredentialStubProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "OpenUsageTests.FirstRunSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class CredentialStubProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { hasCredentials }
}

/// 모든 probe 시작까지 `ProbeGate`에서 suspend — "credential 발견"이 probe 동시 실행을 의미하는 stub
@MainActor
private final class GatedCredentialProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let gate: ProbeGate

    init(id: String, gate: ProbeGate) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.gate = gate
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { await gate.arrive() }
}

/// `expected` 도착까지 suspend 후 일괄 true resume — safety valve가 수 초 뒤 false resume해 suite hang 방지
@MainActor
private final class ProbeGate {
    private let expected: Int
    private var arrived = 0
    private var nextWaiterID = 0
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

    init(expected: Int) {
        self.expected = expected
    }

    func arrive() async -> Bool {
        arrived += 1
        if arrived == expected {
            for waiter in waiters.values {
                waiter.resume(returning: true)
            }
            waiters = [:]
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        return await withCheckedContinuation { continuation in
            waiters[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let waiter = self?.waiters.removeValue(forKey: id) else { return }
                waiter.resume(returning: false)
            }
        }
    }
}
