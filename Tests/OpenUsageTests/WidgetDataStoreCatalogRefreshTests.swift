import os
import XCTest
@testable import OpenUsage

@MainActor
final class WidgetDataStoreCatalogRefreshTests: XCTestCase {
    func testUnrelatedCatalogChangeSchedulesImmediateRefreshForDiscardedClaudeSnapshot() async throws {
        let suite = "OpenUsageTests.CatalogRefresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(start)
        let originalClaude = runtime("claude", at: start)
        let originalCodex = runtime("codex", at: start)
        let store = WidgetDataStore(
            registry: .from([originalClaude, originalCodex]),
            providers: [originalClaude, originalCodex],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { clock.date }),
            defaults: defaults,
            now: { clock.date },
            providerIdentityKeys: ["codex": "codex-account-a"]
        )
        await store.refreshAll(cadence: .claude)
        XCTAssertEqual(originalClaude.refreshCount, 1)
        XCTAssertNotNil(store.localSnapshots["claude"])
        XCTAssertEqual(store.scheduledRefreshDate(for: "claude"), start.addingTimeInterval(900))

        clock.date = start.addingTimeInterval(1)
        let replacementClaude = runtime("claude", at: clock.date)
        let replacementCodex = runtime("codex", at: clock.date)
        let addedCodex = runtime("codex@second", at: clock.date)
        store.replaceProviderCatalog(
            registry: .from([replacementClaude, replacementCodex, addedCodex]),
            providers: [replacementClaude, replacementCodex, addedCodex],
            identityKeys: ["codex": "codex-account-a", "codex@second": "codex-account-b"]
        )
        XCTAssertNil(store.localSnapshots["claude"])
        XCTAssertNil(store.errorMessage(for: "claude"))

        // AppContainer는 새 Codex 카드만 직접 조회하고, 기존 Claude는 cadence wake에 맡김.
        await store.refreshAfterAccountSelection(providerID: "codex@second")
        await store.refreshAll(cadence: .claude)

        XCTAssertEqual(replacementClaude.refreshCount, 1,
                       "Discarding a live Claude snapshot must make its replacement due immediately")
        XCTAssertNotNil(store.localSnapshots["claude"],
                        "An unrelated Codex account addition must not leave Claude empty until its old 15-minute deadline")
    }

    func testCatalogReplacementPreservesKnownAccountRefreshSchedule() async throws {
        let suite = "OpenUsageTests.CatalogRefresh.Known.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = Clock(start)
        let original = runtime("claude", at: start)
        let store = WidgetDataStore(
            registry: .from([original]), providers: [original],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { clock.date }),
            defaults: defaults, now: { clock.date }, providerIdentityKeys: ["claude": "account-a"]
        )
        await store.refreshAll(cadence: .claude)
        let originalSnapshot = store.localSnapshots["claude"]
        clock.date = start.addingTimeInterval(1)
        let replacement = runtime("claude", at: clock.date)
        let addedCodex = runtime("codex@second", at: clock.date)
        store.replaceProviderCatalog(
            registry: .from([replacement, addedCodex]), providers: [replacement, addedCodex],
            identityKeys: ["claude": "account-a", "codex@second": "codex-account-b"]
        )

        await store.refreshAll(cadence: .claude)

        XCTAssertEqual(replacement.refreshCount, 0)
        XCTAssertEqual(store.localSnapshots["claude"], originalSnapshot)
        XCTAssertEqual(store.scheduledRefreshDate(for: "claude"), start.addingTimeInterval(900))
        clock.date = start.addingTimeInterval(900)
        await store.refreshAll(cadence: .claude)
        XCTAssertEqual(replacement.refreshCount, 1)
    }

    func testDiscardedClaudeSnapshotReloadsWithoutBypassingSavedRateLimit() async throws {
        let suite = "OpenUsageTests.CatalogRefresh.Cooldown.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = OSAllocatedUnfairLock(initialState: start)
        let usageRequests = OSAllocatedUnfairLock(initialState: 0)
        let http = RoutingHTTPClient { request in
            if request.url.path == "/api/oauth/profile" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"account":{"uuid":"account-a"},"organization":{"uuid":"org-a"}}"#.utf8
                ))
            }
            let count = usageRequests.withLock { $0 += 1; return $0 }
            return HTTPResponse(statusCode: count == 2 ? 429 : 200, headers: [:], body: Data(
                #"{"five_hour":{"utilization":40}}"#.utf8
            ))
        }
        let files = FakeFiles([
            "/tmp/claude-catalog-fixture/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        ])
        let usageState = isolatedClaudeUsageStore()
        func makeClaude() -> ClaudeProvider {
            ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude-catalog-fixture"]),
                    files: files, keychain: FakeKeychain(), allowsDesktopFallback: false
                ),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: usageState,
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includePiUsage: false,
                now: { clock.withLock { $0 } }, pricing: { TestPricing.bundled }
            )
        }
        let original = makeClaude()
        let store = WidgetDataStore(
            registry: .from([original]), providers: [original],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { clock.withLock { $0 } }),
            defaults: defaults, now: { clock.withLock { $0 } }
        )
        await store.refreshAll(cadence: .claude)
        clock.withLock { $0 = start.addingTimeInterval(1) }
        let limited = await store.refresh(providerID: "claude", force: true, trigger: .manual)
        XCTAssertEqual(limited, .refreshed)
        let retryAfter = try XCTUnwrap(store.localSnapshots["claude"]?.usageRetryAfter)
        XCTAssertEqual(retryAfter, start.addingTimeInterval(901))
        XCTAssertEqual(usageRequests.withLock { $0 }, 2)

        clock.withLock { $0 = start.addingTimeInterval(2) }
        let replacement = makeClaude()
        let addedCodex = runtime("codex@second", at: clock.withLock { $0 })
        store.replaceProviderCatalog(
            registry: .from([replacement, addedCodex]), providers: [replacement, addedCodex],
            identityKeys: ["codex@second": "codex-account-b"]
        )
        XCTAssertNil(store.localSnapshots["claude"])
        await store.refreshAll(cadence: .claude)

        XCTAssertNotNil(store.localSnapshots["claude"])
        XCTAssertEqual(store.localSnapshots["claude"]?.usageRetryAfter, retryAfter)
        XCTAssertEqual(store.localSnapshots["claude"]?.quotaObservedAt, start)
        XCTAssertNil(store.localSnapshots["claude"]?.liveQuotaObservedAt)
        XCTAssertEqual(usageRequests.withLock { $0 }, 2,
                       "Reloading the cleared card must not send usage during its persisted cooldown")
        await store.refreshAll(cadence: .claude)
        XCTAssertEqual(usageRequests.withLock { $0 }, 2)
    }

    private func runtime(_ id: String, at date: Date) -> CountingProviderRuntime {
        let provider = Provider(id: id, displayName: id, icon: .providerMark("claude"))
        return CountingProviderRuntime(
            provider: provider,
            descriptors: [],
            snapshot: ProviderSnapshot(
                providerID: id, displayName: id,
                lines: [.progress(label: "Session", used: 40, limit: 100, format: .percent)],
                refreshedAt: date, quotaObservedAt: date
            )
        )
    }

    private final class Clock {
        var date: Date
        init(_ date: Date) { self.date = date }
    }
}
