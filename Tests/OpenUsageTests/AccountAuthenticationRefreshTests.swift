import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class AccountAuthenticationRefreshTests: XCTestCase {
    func testSwitchBlocksNewUsageUntilAppliedAuthenticationReachesCatalog() async throws {
        let f = try fixture()
        let gate = pauseAfterAuthenticationApply(f)
        defer { gate.release() }
        let switching = Task { try await f.switcher.switchAuthentication(to: f.target, in: f.profiles) }
        await fulfillment(of: [gate.entered], timeout: 3)

        XCTAssertTrue(f.profiles.isApplyingAuthentication)
        XCTAssertEqual(try currentSharedIdentity(f), f.target.identityKey)
        XCTAssertEqual(f.profiles.preferredProfileID(family: "codex"), f.current.id)
        XCTAssertEqual(f.catalog.identity, f.current.identityKey)
        let blocked = await f.store.refresh(providerID: "codex", force: true, trigger: .manual)
        let accountsBeforeCatalog = await f.http.usageAccounts
        XCTAssertEqual(blocked, .skipped)
        XCTAssertTrue(accountsBeforeCatalog.isEmpty, "A's card must not fetch with the already-applied B credential")
        XCTAssertEqual(f.store.localSnapshots["codex"], f.lastGood)
        XCTAssertEqual(f.cache.snapshot(providerID: "codex"), f.lastGood)
        let unrelated = await f.store.refresh(providerID: "cursor", force: true, trigger: .manual)
        XCTAssertEqual(unrelated, .refreshed)

        gate.release()
        try await switching.value

        XCTAssertEqual(f.catalog.identity, f.target.identityKey)
        XCTAssertEqual(f.catalog.callbackCount, 1)
        XCTAssertTrue(f.catalog.wasSuspendedDuringUpdate)
        XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        XCTAssertNil(f.store.localSnapshots["codex"])
        let refreshed = await f.store.refresh(providerID: "codex", force: true, trigger: .manual)
        XCTAssertEqual(refreshed, .refreshed)
        XCTAssertEqual(sessionUsage(f.store), 82)
        XCTAssertFalse(f.cache.hasStaleAccountStamp(providerID: "codex", currentIdentityKey: f.target.identityKey))
        XCTAssertTrue(f.cache.hasStaleAccountStamp(providerID: "codex", currentIdentityKey: f.current.identityKey))
    }

    func testSwitchDiscardsUsageAlreadyInFlightBeforeCatalogChanges() async throws {
        let f = try fixture(blocksUsage: true)
        let refreshing = Task { await f.store.refresh(providerID: "codex", force: true, trigger: .manual) }
        await fulfillment(of: [f.http.usageEntered], timeout: 3)
        let gate = pauseAfterAuthenticationApply(f)
        defer { gate.release() }
        let switching = Task { try await f.switcher.switchAuthentication(to: f.target, in: f.profiles) }
        await fulfillment(of: [gate.entered], timeout: 3)

        await f.http.releaseUsage()
        let outcome = await refreshing.value

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(f.catalog.callbackCount, 0, "The old result returns while authentication apply is still suspended")
        XCTAssertEqual(f.store.localSnapshots["codex"], f.lastGood)
        XCTAssertEqual(f.cache.snapshot(providerID: "codex"), f.lastGood)
        XCTAssertNil(f.store.refreshResults["codex"])

        gate.release()
        try await switching.value
        XCTAssertTrue(f.catalog.wasSuspendedDuringUpdate)
    }

    func testCancelledSwitchCannotPublishPreviouslyStartedUsageAfterGateReopens() async throws {
        let f = try fixture(blocksUsage: true, authenticationIssue: .sessionExpired)
        let refreshing = Task { await f.store.refresh(providerID: "codex", force: true, trigger: .manual) }
        await fulfillment(of: [f.http.usageEntered], timeout: 3)
        f.store.setExternalProviderError("Session expired", for: "codex")
        let previousFailure = f.store.refreshResults["codex"]
        let gate = f.keychain.gateNext(
            .read, service: AccountCredentialVault.service(family: "codex", profileID: f.target.id)
        )
        defer { gate.release() }
        let switching = Task { try await f.switcher.switchAuthentication(to: f.target, in: f.profiles) }
        await fulfillment(of: [gate.entered], timeout: 3)
        switching.cancel()
        gate.release()
        do {
            try await switching.value
            XCTFail("Expected cancellation before authentication apply")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        XCTAssertEqual(f.catalog.identity, f.current.identityKey)
        XCTAssertEqual(f.catalog.replacementCount, 0)
        XCTAssertEqual(f.store.refreshResults["codex"], previousFailure)
        XCTAssertEqual(f.store.localSnapshots["codex"], f.lastGood)

        await f.http.releaseUsage()
        let outcome = await refreshing.value

        XCTAssertEqual(outcome, .skipped, "Mutation generation must outlive the temporary suspension")
        XCTAssertEqual(f.store.refreshResults["codex"], previousFailure)
        XCTAssertEqual(f.cache.snapshot(providerID: "codex"), f.lastGood)
        let retried = await f.store.refresh(providerID: "codex", force: true, trigger: .manual)
        XCTAssertEqual(retried, .refreshed)
        XCTAssertEqual(sessionUsage(f.store), 11)
    }

    func testFailedSwitchPreservesSignInNeededSnapshotAndError() async throws {
        let f = try fixture(authenticationIssue: .signInNeeded)
        try AccountCredentialVault(keychain: f.keychain).delete(profile: f.target)
        f.store.setExternalProviderError("Sign in again", for: "codex")
        let previousFailure = f.store.refreshResults["codex"]
        let wakes = AuthenticationScheduleWakes()
        defer { wakes.stop() }

        do {
            try await f.switcher.switchAuthentication(to: f.target, in: f.profiles)
            XCTFail("Expected missing target authentication")
        } catch {
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .missingSnapshot(f.target.label))
        }

        XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        XCTAssertEqual(f.store.refreshResults["codex"], previousFailure)
        XCTAssertEqual(f.store.localSnapshots["codex"], f.lastGood)
        XCTAssertEqual(f.cache.snapshot(providerID: "codex"), f.lastGood)
        XCTAssertEqual(f.catalog.replacementCount, 0)
        XCTAssertEqual(wakes.count, 1, "An explicit failed switch must still resume the refresh schedule")
    }

    func testRepeatedBackgroundSwitchRecoveryFailureDoesNotWakeItself() async throws {
        let f = try fixture()
        try f.keychain.writeGenericPassword(service: AccountSwitchJournal.service, value: "invalid-journal")
        let importer = importer(for: f)
        let wakes = AuthenticationScheduleWakes()
        defer { wakes.stop() }

        for _ in 0..<3 {
            do {
                _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: f.profiles)
                XCTFail("Expected the unchanged invalid switch journal to block recovery")
            } catch {
                XCTAssertEqual(error as? AccountSwitchJournal.Error, .invalidRecord)
            }
            XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        }

        XCTAssertEqual(f.catalog.callbackCount, 3)
        XCTAssertEqual(wakes.count, 0)
        XCTAssertEqual(try f.keychain.readGenericPassword(service: AccountSwitchJournal.service), "invalid-journal")
    }

    func testRepeatedBackgroundIdentityRecoveryFailureDoesNotWakeItself() async throws {
        let f = try fixture()
        let transaction = try f.profiles.beginIdentityReplacement(
            profileID: f.current.id, with: "replacement", replacesSharedAuthentication: true,
            replacementSnapshotDigest: entry(account: "replacement").snapshotDigest()
        )
        try AccountCredentialVault(keychain: f.keychain).delete(profile: f.current)
        let importer = importer(for: f)
        let wakes = AuthenticationScheduleWakes()
        defer { wakes.stop() }

        for _ in 0..<3 {
            do {
                _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: f.profiles)
                XCTFail("Expected the missing recovery snapshot to keep the transaction pending")
            } catch {
                XCTAssertEqual(error as? AccountIdentityReplacementError, .invalidTransaction)
            }
            XCTAssertEqual(try f.profiles.pendingIdentityReplacement(), transaction)
            XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        }

        XCTAssertEqual(f.catalog.callbackCount, 3)
        XCTAssertEqual(wakes.count, 0)
    }

    func testCommittedSwitchCleanupFailureDoesNotWakeBackgroundRecoveryAgain() async throws {
        let f = try fixture()
        let home = f.sharedHome.deletingLastPathComponent()
        let switcher = AccountCredentialSwitcher(
            keychain: AuthenticationCleanupFailingKeychain(storage: f.keychain),
            environment: FakeEnvironment(), homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        )
        try await switcher.switchAuthentication(to: f.target, in: f.profiles)
        let transaction = try XCTUnwrap(f.switcher.switchJournal.load())
        XCTAssertEqual(f.catalog.identity, f.target.identityKey)
        let wakes = AuthenticationScheduleWakes()
        defer { wakes.stop() }

        for _ in 0..<3 {
            let changed = try await switcher.recoverInterruptedSwitchAfterStartup(in: f.profiles)
            XCTAssertFalse(changed)
            XCTAssertEqual(try f.switcher.switchJournal.load(), transaction)
            XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        }

        XCTAssertEqual(wakes.count, 0)
    }

    func testExistingRefreshSuspensionRemainsActiveAfterAccountMutation() async throws {
        let f = try fixture(suspendsCodex: true)
        try await f.switcher.switchAuthentication(to: f.target, in: f.profiles)

        let outcome = await f.store.refresh(providerID: "codex", force: true, trigger: .manual)

        XCTAssertFalse(f.profiles.isAuthenticationMutationInProgress)
        XCTAssertEqual(outcome, .skipped)
        let requests = await f.http.usageAccounts
        XCTAssertTrue(requests.isEmpty)
    }

    private func fixture(
        blocksUsage: Bool = false, suspendsCodex: Bool = false,
        authenticationIssue: ProviderAuthenticationIssue? = nil
    ) throws -> Fixture {
        let suite = "AccountAuthenticationRefreshTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let profiles = AccountProfilesStore(defaults: defaults)
        let keychain = GatedMutationKeychain()
        let files = GatedMutationFileManager()
        let switcher = AccountCredentialSwitcher(
            keychain: keychain, fileManager: files, environment: FakeEnvironment(), homeDirectory: root,
            workspace: AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
        )
        let current = try profiles.add(family: "codex", label: "Current", identityKey: "current", id: "current")
        let target = try profiles.add(family: "codex", label: "Target", identityKey: "target", id: "target")
        let currentEntry = entry(account: "current")
        try switcher.saveSnapshot(currentEntry, for: current)
        try switcher.saveSnapshot(entry(account: "target"), for: target)
        try switcher.applySharedAuthentication(currentEntry, family: "codex")
        let sharedHome = root.appendingPathComponent(".codex")
        let http = AuthenticationRefreshHTTP(blocksUsage: blocksUsage)
        let runtime = Self.provider(home: sharedHome, keychain: keychain, http: http, profileID: current.id)
        let cursor = CountingProviderRuntime(
            provider: Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor")),
            descriptors: [], snapshot: ProviderSnapshot(providerID: "cursor", displayName: "Cursor", lines: [])
        )
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let lastGood = ProviderSnapshot(
            providerID: "codex", displayName: "Codex",
            lines: [.progress(label: "Session", used: 3, limit: 100, format: .percent)],
            warning: authenticationIssue.map { _ in "Sign in again for live usage" },
            authenticationIssue: authenticationIssue
        )
        cache.store(lastGood, producedByIdentityKey: current.identityKey)
        let store = WidgetDataStore(
            registry: .from([runtime, cursor]), providers: [runtime, cursor], cache: cache, defaults: defaults,
            providerRefreshTimeout: 4, providerIdentityKeys: ["codex": current.identityKey]
        )
        store.isRefreshSuspended = { suspendsCodex && $0 == "codex" }
        let catalog = CatalogObservation(identity: current.identityKey)
        store.coordinateAccountAuthentication(profiles) { [weak store, weak profiles] in
            guard let store, let profiles else { return }
            catalog.callbackCount += 1
            catalog.wasSuspendedDuringUpdate = profiles.isAuthenticationMutationInProgress
                && store.isRefreshSuspended?("codex") == true
            guard let text = try? String(contentsOf: sharedHome.appendingPathComponent("auth.json"), encoding: .utf8),
                  let identity = DefaultAccountObserver.codexFileIdentity(authText: text)?.identityKey else {
                XCTFail("Expected the shared authentication to remain readable")
                return
            }
            guard identity != catalog.identity else { return }
            catalog.identity = identity
            catalog.replacementCount += 1
            let replacement = Self.provider(
                home: sharedHome, keychain: keychain, http: http,
                profileID: profiles.preferredProfileID(family: "codex")
            )
            store.replaceProviderCatalog(
                registry: .from([replacement, cursor]), providers: [replacement, cursor],
                identityKeys: ["codex": identity]
            )
        }
        return Fixture(
            profiles: profiles, keychain: keychain, files: files, switcher: switcher,
            current: current, target: target, sharedHome: sharedHome, http: http,
            store: store, cache: cache, lastGood: lastGood, catalog: catalog
        )
    }

    private func pauseAfterAuthenticationApply(_ f: Fixture) -> MutationKeychainGate {
        let authURL = f.sharedHome.appendingPathComponent("auth.json")
            .resolvingSymlinksInPath().standardizedFileURL
        return f.files.gateNextAttributesOfItem(atPath: authURL.path) {
            (try? String(contentsOf: authURL, encoding: .utf8))?.contains("target-token") == true
        }
    }

    private func importer(for f: Fixture) -> AccountCredentialImporter {
        let home = f.sharedHome.deletingLastPathComponent()
        return AccountCredentialImporter(
            keychain: f.keychain, fileManager: f.files, environment: FakeEnvironment(), homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        )
    }

    private func currentSharedIdentity(_ f: Fixture) throws -> String? {
        let text = try String(contentsOf: f.sharedHome.appendingPathComponent("auth.json"), encoding: .utf8)
        return DefaultAccountObserver.codexFileIdentity(authText: text)?.identityKey
    }

    private static func provider(
        home: URL, keychain: GatedMutationKeychain, http: AuthenticationRefreshHTTP, profileID: String?
    ) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: LocalTextFileAccessor(), keychain: keychain,
                scope: .home(path: home.path), managedSnapshotProfileID: profileID
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(
                environment: FakeEnvironment(),
                incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
                cacheIdentityOverride: UUID().uuidString, rootsOverride: []
            ),
            includePiUsage: false, pricing: { .empty }
        )
    }

    private func entry(account: String) -> AccountCredentialVault.Entry {
        .init(
            credential: #"{"tokens":{"access_token":"\#(account)-token","account_id":"\#(account)"}}"#,
            claudeOAuthAccount: nil
        )
    }

    private func sessionUsage(_ store: WidgetDataStore) -> Double? {
        guard case .progress(_, let used, _, _, _, _, _) = store.localSnapshots["codex"]?.lines.first else {
            return nil
        }
        return used
    }

    private final class CatalogObservation {
        var identity: String
        var callbackCount = 0
        var replacementCount = 0
        var wasSuspendedDuringUpdate = false
        init(identity: String) { self.identity = identity }
    }

    private struct Fixture {
        let profiles: AccountProfilesStore
        let keychain: GatedMutationKeychain
        let files: GatedMutationFileManager
        let switcher: AccountCredentialSwitcher
        let current: AccountProfile
        let target: AccountProfile
        let sharedHome: URL
        let http: AuthenticationRefreshHTTP
        let store: WidgetDataStore
        let cache: ProviderSnapshotCache
        let lastGood: ProviderSnapshot
        let catalog: CatalogObservation
    }
}

private actor AuthenticationRefreshHTTP: HTTPClient {
    nonisolated let usageEntered = XCTestExpectation(description: "Usage request entered")
    private(set) var usageAccounts: [String] = []
    private var blocksUsage: Bool
    private var continuation: CheckedContinuation<Void, Never>?

    init(blocksUsage: Bool) { self.blocksUsage = blocksUsage }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.url == CodexUsageClient.usageURL else {
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"credits":[]}"#.utf8))
        }
        let account = request.headers["ChatGPT-Account-Id"] ?? "missing"
        usageAccounts.append(account)
        if blocksUsage {
            await withCheckedContinuation {
                continuation = $0
                usageEntered.fulfill()
            }
        }
        let used = account == "target" ? 82 : 11
        let body = #"{"rate_limit":{"primary_window":{"used_percent":\#(used),"limit_window_seconds":18000}},"credits":[]}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func releaseUsage() {
        blocksUsage = false
        continuation?.resume()
        continuation = nil
    }
}

private final class AuthenticationScheduleWakes: @unchecked Sendable {
    private let lock = NSLock()
    private var observedCount = 0
    private var observer: NSObjectProtocol?

    var count: Int { lock.withLock { observedCount } }

    init() {
        observer = NotificationCenter.default.addObserver(
            forName: WidgetDataStore.refreshScheduleDidChange, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            lock.withLock { observedCount += 1 }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

private struct AuthenticationCleanupFailingKeychain: KeychainAccessing {
    let storage: GatedMutationKeychain

    func readGenericPassword(service: String) throws -> String? {
        try storage.readGenericPassword(service: service)
    }

    func writeGenericPassword(service: String, value: String) throws {
        try storage.writeGenericPassword(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        if service == AccountSwitchJournal.service { throw MutationKeychainError.injectedWrite }
        try storage.deleteGenericPassword(service: service)
    }
}
