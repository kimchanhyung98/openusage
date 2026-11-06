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
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
        XCTAssertTrue(onboarding.isCustomizeHintPending)
        // 현재 출시 provider 전부 "seen" baseline 처리 — `NewProviderSeeder`는 이후 릴리스 추가분만 probe
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "cursor", "grok", "kimi"])

        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testNothingDetectedKeepsClaudeAndCodexFallback() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("none"))
        let onboarding = OnboardingStore(defaults: makeDefaults("none-onboarding"))
        let providers = ["claude", "codex", "kimi", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement, onboarding: onboarding
        )
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
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

        XCTAssertEqual(enablement.enabledIDs, ["claude"])
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
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])

        await task.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testReseedKeepsClaudeAndCodexFallbackWhenNothingDetected() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-none"))
        enablement.seedEnabledProviders(["grok"])
        let providers = ["claude", "codex", "kimi", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
    }

    func testReseedUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-toggle"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("kimi", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        // probe 진행 중 사용자 toggle — 사용자 선택 우선
        enablement.setEnabled(false, for: "codex")
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude"])
    }

    // MARK: - Sequential detection

    func testCancelledDetectionKeepsFallbackInsteadOfPartialResult() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("cancelled"))
        let onboarding = OnboardingStore(defaults: makeDefaults("cancelled-onboarding"))
        let first = expectation(description: "First probe started")
        let gate = ProbeGate(onFirst: { first.fulfill() })
        let providers: [ProviderRuntime] = [
            GatedCredentialProvider(id: "cursor", gate: gate),
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: true)
        ]
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers, enablement: enablement, onboarding: onboarding
        )
        await fulfillment(of: [first], timeout: 2)
        task?.cancel()
        gate.releaseFirst()
        await task?.value

        XCTAssertEqual(gate.arrivals, ["cursor"])
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
    }

    func testDetectLocalProvidersProbesInOrder() async {
        let ids = ["claude", "codex", "cursor", "grok"]
        let first = expectation(description: "First probe started")
        let gate = ProbeGate(onFirst: { first.fulfill() })
        let providers = ids.map { GatedCredentialProvider(id: $0, gate: gate) }
        let task = Task { await FirstRunSeeder.detectLocalProviders(providers) }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(gate.arrivals, ["claude"])
        gate.releaseFirst()
        let detected = await task.value
        XCTAssertEqual(detected, Set(ids))
        XCTAssertEqual(gate.arrivals, ids)
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

/// 첫 probe를 보류해 뒤의 탐지가 먼저 시작하지 않는지 확인.
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

    func hasLocalCredentials() async -> Bool { await gate.arrive(provider.id) }
}

@MainActor
private final class ProbeGate {
    private(set) var arrivals: [String] = []
    private let onFirst: () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?

    init(onFirst: @escaping () -> Void) { self.onFirst = onFirst }

    func arrive(_ id: String) async -> Bool {
        arrivals.append(id)
        guard arrivals.count == 1 else { return true }
        return await withCheckedContinuation {
            continuation = $0
            onFirst()
        }
    }

    func releaseFirst() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}
