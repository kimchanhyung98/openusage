import Observation
import XCTest
@testable import OpenUsage

@MainActor
final class AccountStatusTests: XCTestCase {
    func testExpiredCodexRefreshOverridesLocallyReadySnapshot() async throws {
        let profile = AccountProfile(
            id: "expired", family: "codex", label: "ch", identityKey: "account-ch", createdAt: .distantPast
        )
        let keychain = ServiceKeychain()
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"tokens":{"access_token":"old-access","refresh_token":"old-refresh","account_id":"account-ch"},"last_refresh":"2000-01-01T00:00:00Z"}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        let localState = AccountSignInProbe(
            environment: FakeEnvironment([:]), keychain: keychain,
            homeDirectory: { URL(fileURLWithPath: "/unused-account-status-test") }
        ).state(for: profile)
        XCTAssertTrue(localState.isReady)
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 401, headers: [:],
            body: Data(#"{"error":{"code":"refresh_token_expired"}}"#.utf8)
        ))
        let runtime = CodexProvider(
            provider: CodexProvider.makeProvider(id: AccountUsageCardPlanner.cardID(family: "codex", profileID: profile.id)),
            authStore: CodexAuthStore(
                environment: FakeEnvironment([:]), keychain: keychain,
                scope: .accountSnapshot(profileID: profile.id)
            ),
            usageClient: CodexUsageClient(http: http), includePiUsage: false
        )
        let defaults = makeDefaults()
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
        )

        await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(store.errorMessage(for: runtime.provider.id), CodexAuthError.sessionExpired.localizedDescription)
        let status = store.accountStatus(for: runtime.provider.id, localState: localState)
        XCTAssertEqual(status.title, "Session Expired")
        XCTAssertFalse(status.canSwitch)
    }

    func testTokenConflictsAndRevocationsRequireSignInWithoutCallingThemExpired() async {
        for error in [CodexAuthError.tokenConflict, .tokenRevoked, .tokenExpired, .invalidAuthPayload] {
            let runtime = AccountStatusRuntime()
            runtime.snapshot = .error(provider: runtime.provider, error: error)
            let store = makeStore(runtime)

            await store.refresh(providerID: runtime.provider.id, force: true)

            XCTAssertEqual(status(in: store), .signInNeeded(error.localizedDescription))
            XCTAssertFalse(status(in: store).canSwitch)
        }
    }

    func testTransientFailuresKeepSwitchingAvailableAndRecoverAfterSuccess() async {
        for error in [CodexUsageError.connectionFailed, .requestFailed(503), .requestFailed(429), .requestFailed(401)] {
            let runtime = AccountStatusRuntime()
            let successful = runtime.snapshot
            runtime.snapshot = .error(provider: runtime.provider, error: error)
            let store = makeStore(runtime)
            await store.refresh(providerID: runtime.provider.id, force: true)
            XCTAssertEqual(status(in: store), .refreshFailed(error.localizedDescription))
            XCTAssertTrue(status(in: store).canSwitch)

            runtime.snapshot = successful
            await store.refresh(providerID: runtime.provider.id, force: true)

            XCTAssertEqual(status(in: store), .ready)
            XCTAssertNil(store.headerNotice(for: runtime.provider.id))
        }
    }

    func testPersistedUsageDoesNotCountAsSuccessfulAuthenticationInANewLaunch() async {
        let runtime = AccountStatusRuntime()
        let defaults = makeDefaults()
        ProviderSnapshotCache(userDefaults: defaults).store(runtime.snapshot)
        let store = makeStore(runtime, defaults: defaults)

        XCTAssertNotNil(store.localSnapshots[runtime.provider.id])
        XCTAssertEqual(status(in: store), .notChecked)
        XCTAssertTrue(status(in: store).canSwitch)

        await store.refresh(providerID: runtime.provider.id)

        XCTAssertEqual(status(in: store), .ready)
    }

    func testFailureRetainsUsageAndIsNotClearedByReadingTheFreshCache() async {
        let runtime = AccountStatusRuntime()
        let store = makeStore(runtime)
        await store.refresh(providerID: runtime.provider.id, force: true)
        let previous = store.localSnapshots[runtime.provider.id]
        runtime.snapshot = .error(provider: runtime.provider, error: CodexAuthError.sessionExpired)
        let changed = expectation(description: "open settings observes the failure")
        withObservationTracking {
            XCTAssertEqual(status(in: store), .ready)
        } onChange: {
            changed.fulfill()
        }

        await store.refresh(providerID: runtime.provider.id, force: true)
        await fulfillment(of: [changed], timeout: 1)
        let cacheResult = await store.refresh(providerID: runtime.provider.id)

        XCTAssertEqual(cacheResult, .cacheHit)
        XCTAssertEqual(store.localSnapshots[runtime.provider.id], previous)
        XCTAssertEqual(status(in: store), .sessionExpired(CodexAuthError.sessionExpired.localizedDescription))
    }

    func testReauthenticationClearsTheOldVerdictAndBypassesCacheAndBackoff() async {
        let runtime = AccountStatusRuntime()
        let successful = runtime.snapshot
        let store = makeStore(runtime)
        await store.refresh(providerID: runtime.provider.id, force: true)
        runtime.snapshot = .error(provider: runtime.provider, error: CodexAuthError.sessionExpired)
        await store.refresh(providerID: runtime.provider.id, force: true)

        store.invalidateAuthentication(for: runtime.provider.id)

        XCTAssertEqual(status(in: store), .notChecked)
        XCTAssertNil(store.headerNotice(for: runtime.provider.id))
        runtime.snapshot = successful
        let outcome = await store.refresh(providerID: runtime.provider.id)
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(status(in: store), .ready)
    }

    func testReauthenticationClearsPartialUsageAuthenticationWarningWhileKeepingUsage() async {
        let runtime = AccountStatusRuntime(id: "claude")
        runtime.snapshot.plan = "Pro"
        runtime.snapshot.refreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
        runtime.snapshot.usageHistory = ProviderUsageHistory(series: .init(daily: [
            .init(date: "2026-09-11", totalTokens: 1200, costUSD: 0.25)
        ]))
        var expected = runtime.snapshot
        runtime.snapshot.warning = ClaudeUsageMapper.missingProfileScopeWarning
        runtime.snapshot.authenticationIssue = .signInNeeded
        let store = makeStore(runtime)
        await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(store.headerNotice(for: "claude"), ClaudeUsageMapper.missingProfileScopeWarning)
        XCTAssertFalse(status(in: store, providerID: "claude").canSwitch)

        store.invalidateAuthentication(for: "claude")

        XCTAssertEqual(status(in: store, providerID: "claude"), .notChecked)
        XCTAssertNil(store.headerNotice(for: "claude"))
        XCTAssertEqual(store.localSnapshots["claude"], expected)
        XCTAssertEqual(store.snapshots["claude"], expected)

        runtime.suspends = true
        let started = expectation(description: "replacement refresh started")
        runtime.onStart = { started.fulfill() }
        let refresh = Task { await store.refresh(providerID: "claude") }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(status(in: store, providerID: "claude"), .checking)
        XCTAssertNil(store.headerNotice(for: "claude"))
        XCTAssertEqual(store.snapshots["claude"], expected)

        expected.refreshedAt = expected.refreshedAt.addingTimeInterval(60)
        runtime.finish(expected)
        let outcome = await refresh.value
        XCTAssertEqual(outcome, .refreshed)
        XCTAssertEqual(status(in: store, providerID: "claude"), .ready)
        XCTAssertNil(store.headerNotice(for: "claude"))
    }

    func testReauthenticationPreservesWarningsUnrelatedToAuthentication() async {
        let runtime = AccountStatusRuntime(id: "claude")
        runtime.snapshot.warning = "Updates temporarily rate limited."
        let store = makeStore(runtime)
        await store.refresh(providerID: "claude", force: true)
        let previous = store.localSnapshots["claude"]

        store.invalidateAuthentication(for: "claude")

        XCTAssertEqual(status(in: store, providerID: "claude"), .notChecked)
        XCTAssertEqual(store.headerNotice(for: "claude"), "Updates temporarily rate limited.")
        XCTAssertEqual(store.localSnapshots["claude"], previous)
        XCTAssertEqual(store.snapshots["claude"], previous)
    }

    func testReauthenticationDiscardsThePreviousCredentialsInFlightResult() async {
        let runtime = AccountStatusRuntime()
        runtime.suspends = true
        let started = expectation(description: "refresh started")
        runtime.onStart = { started.fulfill() }
        let store = makeStore(runtime)
        let refresh = Task { await store.refresh(providerID: runtime.provider.id, force: true) }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(status(in: store), .checking)

        store.invalidateAuthentication(for: runtime.provider.id)
        runtime.finish(.error(provider: runtime.provider, error: CodexAuthError.sessionExpired))
        let outcome = await refresh.value

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(status(in: store), .notChecked)
        XCTAssertNil(store.headerNotice(for: runtime.provider.id))
        XCTAssertNil(store.localSnapshots[runtime.provider.id])
    }

    func testNoLocalSignInCannotBecomeReadyFromAUsageResult() async {
        let runtime = AccountStatusRuntime()
        let store = makeStore(runtime)
        await store.refresh(providerID: runtime.provider.id, force: true)

        XCTAssertEqual(store.accountStatus(for: "codex", localState: .needsSignIn), .signInNeeded())
        XCTAssertEqual(store.accountStatus(for: nil, localState: .ready(identityKey: "account", label: nil)), .notChecked)
    }

    func testSelectedAndInactiveProfilesUseTheirOwnResultsEvenWithTheSameIdentity() async throws {
        let profiles = AccountProfilesStore(defaults: makeDefaults())
        let selected = try profiles.add(family: "codex", label: "selected", identityKey: "same-account")
        let inactive = try profiles.add(family: "codex", label: "inactive", identityKey: "same-account")
        let inactiveID = AccountUsageCardPlanner.cardID(family: "codex", profileID: inactive.id)
        let assembly = ProviderAccountAssembly(
            identityKeysByCard: ["codex": "same-account", inactiveID: "same-account"],
            profileIDsByCard: [inactiveID: inactive.id]
        )
        let mapping = AppContainer.accountProfileIDsByCardID(assembly: assembly, profiles: profiles)
        let selectedRuntime = AccountStatusRuntime()
        let inactiveRuntime = AccountStatusRuntime(id: inactiveID)
        inactiveRuntime.snapshot = .error(provider: inactiveRuntime.provider, error: CodexAuthError.sessionExpired)
        let defaults = makeDefaults()
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([selectedRuntime, inactiveRuntime]), providers: [selectedRuntime, inactiveRuntime],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
        )
        await store.refreshAll(force: true)
        let local = AccountSignInProbe.State.ready(identityKey: "same-account", label: nil)

        XCTAssertEqual(store.accountStatus(
            for: AccountUsageCardPlanner.statusCardID(for: selected, profileIDsByCard: mapping), localState: local
        ), .ready)
        XCTAssertEqual(store.accountStatus(
            for: AccountUsageCardPlanner.statusCardID(for: inactive, profileIDsByCard: mapping), localState: local
        ), .sessionExpired(CodexAuthError.sessionExpired.localizedDescription))
    }

    func testAChangedSharedHomeIdentityDoesNotInheritThePreviousAccountsError() async {
        let runtime = AccountStatusRuntime()
        runtime.snapshot = .error(provider: runtime.provider, error: CodexAuthError.sessionExpired)
        let defaults = makeDefaults()
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults,
            providerIdentityKeys: ["codex": "previous"]
        )
        await store.refresh(providerID: "codex", force: true)

        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([runtime]), providers: [runtime], identityKeys: ["codex": "replacement"]
        )

        XCTAssertEqual(status(in: store), .notChecked)
        XCTAssertNil(store.errorMessage(for: "codex"))
    }

    func testPartialClaudeUsageDoesNotHideTheSignInOrRateLimitWarning() async {
        let runtime = AccountStatusRuntime(id: "claude")
        runtime.snapshot.warning = ClaudeUsageMapper.missingProfileScopeWarning
        runtime.snapshot.authenticationIssue = .signInNeeded
        let store = makeStore(runtime)
        await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(status(in: store, providerID: "claude"), .signInNeeded(ClaudeUsageMapper.missingProfileScopeWarning))

        runtime.snapshot.warning = "Updates temporarily rate limited."
        runtime.snapshot.authenticationIssue = nil
        await store.refresh(providerID: "claude", force: true)
        XCTAssertEqual(status(in: store, providerID: "claude"), .refreshFailed("Updates temporarily rate limited."))
        XCTAssertTrue(status(in: store, providerID: "claude").canSwitch)
    }

    func testSameIdentityReSignInRecordsOnlyThatProfilesAuthenticationRevision() throws {
        let profiles = AccountProfilesStore(defaults: makeDefaults())
        let selected = try profiles.add(family: "codex", label: "selected", identityKey: "same-account")
        let other = try profiles.add(family: "codex", label: "other", identityKey: "same-account")
        let transaction = try profiles.beginIdentityReplacement(
            profileID: selected.id, with: selected.identityKey, replacesSharedAuthentication: true
        )

        try profiles.commitIdentityReplacement(transaction)

        XCTAssertEqual(profiles.authenticationRevisionsByProfileID[selected.id], profiles.authenticationRevision)
        XCTAssertNil(profiles.authenticationRevisionsByProfileID[other.id])
    }

    private func status(in store: WidgetDataStore, providerID: String = "codex") -> AccountStatus {
        store.accountStatus(for: providerID, localState: .ready(identityKey: "account", label: nil))
    }

    private func makeStore(_ runtime: AccountStatusRuntime, defaults: UserDefaults? = nil) -> WidgetDataStore {
        let defaults = defaults ?? makeDefaults()
        return WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.AccountStatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}

@MainActor
private final class AccountStatusRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    var snapshot: ProviderSnapshot
    var suspends = false
    var onStart: (() -> Void)?
    private var continuation: CheckedContinuation<ProviderSnapshot, Never>?

    init(id: String = "codex") {
        provider = CodexProvider.makeProvider(id: id)
        snapshot = ProviderSnapshot(
            providerID: id, displayName: "Codex",
            lines: [.progress(label: "Weekly", used: 42, limit: 100, format: .percent)]
        )
    }

    func refresh() async -> ProviderSnapshot {
        guard suspends else { return snapshot }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStart?()
        }
    }

    func finish(_ snapshot: ProviderSnapshot) {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}
