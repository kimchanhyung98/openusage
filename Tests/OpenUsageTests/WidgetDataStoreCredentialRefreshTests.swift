import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreCredentialRefreshTests: XCTestCase {
    private func fixture(blockedKeys: Set<String> = ["fixture-a", "fixture-b"], failedKeys: Set<String> = [],
                         environmentKey: String? = nil, control: CredentialControlProvider? = nil) -> Fixture {
        let suite = "OpenUsageTests.CredentialRefresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let http = CredentialRefreshHTTP(blockedKeys: blockedKeys, failedKeys: failedKeys)
        let environment = environmentKey.map { ["OPENROUTER_API_KEY": $0] } ?? [:]
        let runtime = OpenRouterProvider(
            authStore: OpenRouterAuthStore(files: FakeFiles(), environment: FakeEnvironment(environment)),
            usageClient: OpenRouterUsageClient(http: http)
        )
        let clock = TestClock()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { clock.date })
        let lastGood = ProviderSnapshot(providerID: "openrouter", displayName: "OpenRouter",
                                        lines: [.progress(label: "Credits", used: 7, limit: 100, format: .dollars)])
        cache.store(lastGood)
        let enabled = Enablement()
        let providers: [ProviderRuntime] = [runtime] + (control.map { [$0] } ?? [])
        let store = WidgetDataStore(registry: .from(providers), providers: providers, cache: cache,
                                    defaults: defaults, isProviderEnabled: { _ in enabled.value }, now: { clock.date })
        return Fixture(runtime: runtime, store: store, cache: cache, http: http,
                       enabled: enabled, clock: clock, lastGood: lastGood)
    }

    func testSavingKeyDuringOldRequestDiscardsOldSuccessAndFetchesNewKey() async throws {
        let f = fixture()
        try f.runtime.saveAPIKey("fixture-a")
        let oldRefresh = Task { await f.store.refresh(providerID: "openrouter", force: true) }
        await waitForRequest("fixture-a", in: f.http)

        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        let replacement = Task { await refreshChange(f.store, generation: generation) }
        await f.http.release("fixture-a")
        let oldOutcome = await oldRefresh.value
        await waitForRequest("fixture-b", in: f.http)

        XCTAssertEqual(oldOutcome, .skipped)
        XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
        XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.lastGood)
        await f.http.release("fixture-b")
        await replacement.value

        XCTAssertEqual(creditsUsed(f.store), 82)
        XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.store.localSnapshots["openrouter"])
        let requests = await f.http.keys
        XCTAssertEqual(requests, ["fixture-a", "fixture-a", "fixture-b", "fixture-b"])
    }

    func testOldFailureCannotPublishAnErrorOrBackoffForNewKey() async throws {
        let f = fixture(failedKeys: ["fixture-a"])
        try f.runtime.saveAPIKey("fixture-a")
        let oldRefresh = Task { await f.store.refresh(providerID: "openrouter", force: true) }
        await waitForRequest("fixture-a", in: f.http)
        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        let replacement = Task { await refreshChange(f.store, generation: generation) }
        await f.http.release("fixture-a")
        let oldOutcome = await oldRefresh.value
        await waitForRequest("fixture-b", in: f.http)

        XCTAssertEqual(oldOutcome, .skipped)
        XCTAssertNil(f.store.providerErrors["openrouter"])
        XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.lastGood)
        await f.http.release("fixture-b")
        await replacement.value
        XCTAssertEqual(creditsUsed(f.store), 82)
    }

    func testDeletingSavedKeyRefreshesEnvironmentFallbackOrMissingKeyState() async throws {
        for environmentKey in ["fixture-c", nil] as [String?] {
            let f = fixture(blockedKeys: ["fixture-a", "fixture-c"], environmentKey: environmentKey)
            try f.runtime.saveAPIKey("fixture-a")
            let oldRefresh = Task { await f.store.refresh(providerID: "openrouter", force: true) }
            await waitForRequest("fixture-a", in: f.http)
            try f.runtime.deleteAPIKey()
            let generation = f.store.credentialsDidChange(for: "openrouter")
            let replacement = Task { await refreshChange(f.store, generation: generation) }
            await f.http.release("fixture-a")
            let oldOutcome = await oldRefresh.value
            XCTAssertEqual(oldOutcome, .skipped)
            XCTAssertEqual(f.runtime.currentAPIKey(), environmentKey)

            if let environmentKey {
                await waitForRequest(environmentKey, in: f.http)
                XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
                await f.http.release(environmentKey)
                await replacement.value
                XCTAssertEqual(creditsUsed(f.store), 93)
                XCTAssertEqual(f.runtime.apiKeyStatus, .fromEnvironment)
            } else {
                await replacement.value
                XCTAssertEqual(f.store.providerErrors["openrouter"], OpenRouterAuthError.missingKey.localizedDescription)
                XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
                XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.lastGood)
                XCTAssertEqual(f.runtime.apiKeyStatus, .notSet)
            }
        }
    }

    func testDisabledKeyChangeBypassesOldCacheAndBackoffWhenReenabled() async throws {
        let f = fixture(blockedKeys: [], failedKeys: ["fixture-a"])
        try f.runtime.saveAPIKey("fixture-a")
        let failure = await f.store.refresh(providerID: "openrouter", force: true)
        XCTAssertEqual(failure, .failed)
        XCTAssertNotNil(f.store.providerErrors["openrouter"])
        f.enabled.value = false
        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        XCTAssertNil(f.store.providerErrors["openrouter"])
        await refreshChange(f.store, generation: generation)
        let beforeEnabling = await f.http.keys
        XCTAssertEqual(beforeEnabling, ["fixture-a", "fixture-a"])
        XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
        XCTAssertNil(f.store.providerErrors["openrouter"])
        XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.lastGood)

        f.enabled.value = true
        let outcome = await f.store.refresh(providerID: "openrouter")

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(creditsUsed(f.store), 82)
        XCTAssertNil(f.store.providerErrors["openrouter"])
    }

    func testKeyChangeClearsPublishedErrorWhileCurrentRequestIsPending() async throws {
        let f = fixture(blockedKeys: ["fixture-b"], failedKeys: ["fixture-a"])
        try f.runtime.saveAPIKey("fixture-a")
        let failure = await f.store.refresh(providerID: "openrouter", force: true)
        XCTAssertEqual(failure, .failed)
        XCTAssertNotNil(f.store.providerErrors["openrouter"])

        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        XCTAssertNil(f.store.providerErrors["openrouter"])
        let replacement = Task { await refreshChange(f.store, generation: generation) }
        await waitForRequest("fixture-b", in: f.http)

        XCTAssertNil(f.store.providerErrors["openrouter"])
        XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
        XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.lastGood)
        await f.http.release("fixture-b")
        await replacement.value
        XCTAssertEqual(creditsUsed(f.store), 82)
    }

    func testNewerKeyChangeSupersedesAnOlderWaitingRefresh() async throws {
        let f = fixture(blockedKeys: ["fixture-a", "fixture-c"])
        try f.runtime.saveAPIKey("fixture-a")
        let oldRefresh = Task { await f.store.refresh(providerID: "openrouter", force: true) }
        await waitForRequest("fixture-a", in: f.http)
        try f.runtime.saveAPIKey("fixture-b")
        let firstGeneration = f.store.credentialsDidChange(for: "openrouter")
        let firstReplacement = Task { await refreshChange(f.store, generation: firstGeneration) }
        await Task.yield()
        try f.runtime.saveAPIKey("fixture-c")
        let lastGeneration = f.store.credentialsDidChange(for: "openrouter")
        let latestReplacement = Task { await refreshChange(f.store, generation: lastGeneration) }
        await f.http.release("fixture-a")
        let oldOutcome = await oldRefresh.value
        await firstReplacement.value
        await waitForRequest("fixture-c", in: f.http)
        XCTAssertEqual(oldOutcome, .skipped)
        XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
        await f.http.release("fixture-c")
        await latestReplacement.value

        let requests = await f.http.keys
        XCTAssertEqual(requests, ["fixture-a", "fixture-a", "fixture-c", "fixture-c"])
        XCTAssertEqual(creditsUsed(f.store), 93)
    }

    func testWaitLimitLeavesNextScheduledRefreshUsingCurrentKey() async throws {
        let f = fixture(blockedKeys: ["fixture-a"], failedKeys: ["fixture-a"])
        try f.runtime.saveAPIKey("fixture-a")
        let oldRefresh = Task { await f.store.refresh(providerID: "openrouter", force: true) }
        await waitForRequest("fixture-a", in: f.http)
        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        await refreshChange(f.store, generation: generation, maxAttempts: 1)
        await f.http.release("fixture-a")
        let oldOutcome = await oldRefresh.value
        XCTAssertEqual(oldOutcome, .skipped)
        XCTAssertNil(f.store.providerErrors["openrouter"])

        let outcome = await f.store.refresh(providerID: "openrouter")

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(creditsUsed(f.store), 82)
    }

    func testCancelledWaitStopsWithoutLosingNextScheduledRefresh() async throws {
        let f = fixture(blockedKeys: ["fixture-a"])
        try f.runtime.saveAPIKey("fixture-a")
        let oldRefresh = Task { await f.store.refresh(providerID: "openrouter", force: true) }
        await waitForRequest("fixture-a", in: f.http)
        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        let replacement = Task { await refreshChange(f.store, generation: generation) }
        replacement.cancel()
        await replacement.value
        let beforeRelease = await f.http.keys
        XCTAssertEqual(beforeRelease, ["fixture-a"])
        await f.http.release("fixture-a")
        let oldOutcome = await oldRefresh.value
        XCTAssertEqual(oldOutcome, .skipped)

        let outcome = await f.store.refresh(providerID: "openrouter")

        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(creditsUsed(f.store), 82)
    }

    func testCurrentKeyFailureKeepsLastGoodButCannotHideRetryBehindOldCache() async throws {
        let f = fixture(blockedKeys: [], failedKeys: ["fixture-b"])
        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        await refreshChange(f.store, generation: generation)
        XCTAssertEqual(f.store.localSnapshots["openrouter"], f.lastGood)
        XCTAssertNotNil(f.store.providerErrors["openrouter"])
        let immediate = await f.store.refresh(providerID: "openrouter")
        XCTAssertEqual(immediate, .backedOff, "the current key's own failure still uses the normal retry delay")

        f.clock.date += 61
        let retried = await f.store.refresh(providerID: "openrouter")

        XCTAssertEqual(retried, .failed, "the old last-good cache must not suppress the current key's retry")
        XCTAssertEqual(f.cache.snapshot(providerID: "openrouter"), f.lastGood)
        let requests = await f.http.keys
        XCTAssertEqual(requests, Array(repeating: "fixture-b", count: 4))
    }

    func testCredentialChangeDoesNotInvalidateAnotherProvidersInFlightResult() async throws {
        let control = CredentialControlProvider()
        let f = fixture(blockedKeys: [], control: control)
        let otherRefresh = Task { await f.store.refresh(providerID: control.provider.id, force: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while control.gate == nil, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertNotNil(control.gate)
        try f.runtime.saveAPIKey("fixture-b")
        let generation = f.store.credentialsDidChange(for: "openrouter")
        await refreshChange(f.store, generation: generation)
        control.gate?.resume()
        let otherOutcome = await otherRefresh.value

        XCTAssertEqual(otherOutcome, .refreshed)
        XCTAssertEqual(f.store.localSnapshots[control.provider.id]?.plan, "Control")
        XCTAssertEqual(creditsUsed(f.store), 82)
    }

    private func refreshChange(_ store: WidgetDataStore, generation: Int, maxAttempts: Int = 45) async {
        await store.refreshAfterCredentialChange(providerID: "openrouter", credentialGeneration: generation,
                                                maxAttempts: maxAttempts, retryDelay: .milliseconds(1))
    }

    private func waitForRequest(_ key: String, in http: CredentialRefreshHTTP,
                                file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await http.keys.contains(key) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("request did not start for \(key)", file: file, line: line)
    }

    private func creditsUsed(_ store: WidgetDataStore) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = store.localSnapshots["openrouter"]?.lines.first else {
            return nil
        }
        return used
    }

    private struct Fixture {
        let runtime: OpenRouterProvider
        let store: WidgetDataStore
        let cache: ProviderSnapshotCache
        let http: CredentialRefreshHTTP
        let enabled: Enablement
        let clock: TestClock
        let lastGood: ProviderSnapshot
    }

    private final class Enablement {
        var value = true
    }

    private final class TestClock {
        var date = Date()
    }
}

@MainActor
private final class CredentialControlProvider: ProviderRuntime {
    let provider = Provider(id: "control", displayName: "Control", icon: .providerMark("codex"))
    let widgetDescriptors: [WidgetDescriptor] = []
    var gate: CheckedContinuation<Void, Never>?

    func refresh() async -> ProviderSnapshot {
        await withCheckedContinuation { gate = $0 }
        return ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, plan: "Control", lines: [])
    }
}

private actor CredentialRefreshHTTP: HTTPClient {
    private var blockedKeys: Set<String>
    private let failedKeys: Set<String>
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private(set) var keys: [String] = []

    init(blockedKeys: Set<String>, failedKeys: Set<String>) {
        self.blockedKeys = blockedKeys
        self.failedKeys = failedKeys
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let key = String((request.headers["Authorization"] ?? "").dropFirst("Bearer ".count))
        keys.append(key)
        if request.url.path == "/api/v1/credits", blockedKeys.contains(key) {
            await withCheckedContinuation { gates[key] = $0 }
        }
        if failedKeys.contains(key) { return HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let used = key == "fixture-a" ? 11 : key == "fixture-b" ? 82 : 93
        let body = request.url.path == "/api/v1/credits"
            ? "{\"data\":{\"total_credits\":100,\"total_usage\":\(used)}}"
            : "{\"data\":{\"usage_daily\":\(used),\"is_free_tier\":false}}"
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func release(_ key: String) {
        blockedKeys.remove(key)
        gates.removeValue(forKey: key)?.resume()
    }
}
