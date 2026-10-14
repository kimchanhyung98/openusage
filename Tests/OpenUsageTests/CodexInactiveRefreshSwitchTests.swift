import XCTest
@testable import OpenUsage

@MainActor
final class CodexInactiveRefreshSwitchTests: XCTestCase {
    func testSwitchAwayMustNotOverwriteRotationFromFormerInactiveRuntime() async throws {
        let home = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("OpenUsageInactiveRefreshSwitch.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let originalLogSink = AppLog.sink
        AppLog.sink = LogFile(directory: home.appendingPathComponent("logs"), fileName: "fixture.log")
        defer { AppLog.sink = originalLogSink }
        let keychain = InactiveRefreshSwitchKeychain()
        let vault = AccountCredentialVault(keychain: keychain)
        let profileA = AccountProfile(
            id: "release-a", family: "codex", label: "A", identityKey: "account-a", createdAt: .distantPast
        )
        let profileB = AccountProfile(
            id: "release-b", family: "codex", label: "B", identityKey: "account-b", createdAt: .distantPast
        )
        let oldA = #"{"tokens":{"access_token":"old-a","refresh_token":"refresh-a","account_id":"account-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        let oldB = #"{"tokens":{"access_token":"old-b","refresh_token":"refresh-b","account_id":"account-b"}}"#
        try vault.save(.init(credential: oldA, claudeOAuthAccount: nil), profile: profileA)
        try vault.save(.init(credential: oldB, claudeOAuthAccount: nil), profile: profileB)
        let switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        )
        try switcher.applySharedAuthentication(.init(credential: oldB, claudeOAuthAccount: nil), family: "codex")
        let sharedHome = home.appendingPathComponent(".codex", isDirectory: true)
        let sharedFile = sharedHome.appendingPathComponent("auth.json")
        let inactiveHTTP = InactiveRefreshSwitchHTTP()
        let selectedHTTP = SelectedRefreshSwitchHTTP()
        let oldInactiveAID = AccountUsageCardPlanner.cardID(family: "codex", profileID: profileA.id)
        let newInactiveBID = AccountUsageCardPlanner.cardID(family: "codex", profileID: profileB.id)
        let oldInactiveA = provider(
            id: oldInactiveAID, scope: .accountSnapshot(profileID: profileA.id), keychain: keychain,
            http: inactiveHTTP, sharedHome: sharedHome.path
        )
        let oldActiveB = provider(
            id: "codex", scope: .home(path: sharedHome.path), keychain: keychain, http: selectedHTTP,
            managedProfileID: profileB.id
        )
        let suite = "CodexInactiveRefreshSwitchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let store = WidgetDataStore(
            registry: .from([oldActiveB, oldInactiveA]), providers: [oldActiveB, oldInactiveA],
            cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "account-b", oldInactiveAID: "account-a"]
        )
        let oldRefresh = Task {
            await store.refresh(providerID: oldInactiveAID, force: true, trigger: .scheduled)
        }
        await inactiveHTTP.waitForRotationRequest()
        XCTAssertTrue(AccountStatus.checking.canSwitch)

        // 실제 전환 순서와 동일하게 target 인증 적용 후 카탈로그와 선택 카드 조회 교체.
        try switcher.switchAuthentication(to: profileA, from: profileB)
        let newActiveA = provider(
            id: "codex", scope: .home(path: sharedHome.path), keychain: keychain, http: selectedHTTP,
            managedProfileID: profileA.id
        )
        let newInactiveB = provider(
            id: newInactiveBID, scope: .accountSnapshot(profileID: profileB.id), keychain: keychain,
            http: selectedHTTP
        )
        store.replaceProviderCatalog(
            registry: .from([newActiveA, newInactiveB]), providers: [newActiveA, newInactiveB],
            identityKeys: ["codex": "account-a", newInactiveBID: "account-b"]
        )
        await store.refreshAfterAccountSelection(providerID: "codex", maxAttempts: 1, retryDelay: .zero)
        let selectedRequests = await selectedHTTP.rotationRequests
        XCTAssertEqual(selectedRequests, 1, "The new runtime refresh is not serialized with the old snapshot runtime")
        XCTAssertNotNil(store.refreshResults["codex"]?.failure)

        await inactiveHTTP.finishRotation()
        let oldOutcome = await oldRefresh.value
        XCTAssertEqual(oldOutcome, .skipped, "Catalog generation correctly rejects publication of the departed runtime")
        let rotated = try XCTUnwrap(vault.load(profile: profileA))
        XCTAssertEqual(CodexAuthStore.parseAuth(rotated.credential)?.tokens?.refreshToken, "rotated-refresh-a")
        let sharedBeforeLeaving = try String(contentsOf: sharedFile, encoding: .utf8)
        XCTAssertEqual(CodexAuthStore.parseAuth(sharedBeforeLeaving)?.tokens?.refreshToken, "rotated-refresh-a")

        try switcher.switchAuthentication(to: profileB, from: profileA)

        let afterSecondSwitch = try XCTUnwrap(vault.load(profile: profileA))
        XCTAssertEqual(
            CodexAuthStore.parseAuth(afterSecondSwitch.credential)?.tokens?.refreshToken,
            "rotated-refresh-a",
            "Switching away must preserve the valid rotated snapshot instead of replacing it with the old shared token"
        )
    }

    private func provider(
        id: String, scope: CodexCredentialScope, keychain: InactiveRefreshSwitchKeychain,
        http: any HTTPClient, managedProfileID: String? = nil, sharedHome: String? = nil
    ) -> CodexProvider {
        CodexProvider(
            provider: CodexProvider.makeProvider(id: id),
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: LocalTextFileAccessor(), keychain: keychain,
                scope: scope, managedSnapshotProfileID: managedProfileID, managedSharedAuthHome: sharedHome
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
}

private actor InactiveRefreshSwitchHTTP: HTTPClient {
    private var enteredRotation = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var responseWaiter: CheckedContinuation<HTTPResponse, Never>?

    func waitForRotationRequest() async {
        guard !enteredRotation else { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func finishRotation() {
        responseWaiter?.resume(returning: HTTPResponse(
            statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"rotated-a","refresh_token":"rotated-refresh-a"}"#.utf8
            )
        ))
        responseWaiter = nil
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url == CodexUsageClient.refreshURL {
            enteredRotation = true
            return await withCheckedContinuation { continuation in
                responseWaiter = continuation
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#.utf8
        ))
    }
}

private actor SelectedRefreshSwitchHTTP: HTTPClient {
    private(set) var rotationRequests = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url == CodexUsageClient.refreshURL {
            rotationRequests += 1
            return HTTPResponse(statusCode: 503, headers: [:], body: Data(
                #"{"error":"temporarily_unavailable"}"#.utf8
            ))
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#.utf8
        ))
    }
}

private final class InactiveRefreshSwitchKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        lock.withLock { values[(forCurrentUser ? "user:" : "service:") + service] }
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock { values["service:" + service] }
    }

    func writeGenericPassword(service: String, value: String) throws {
        lock.withLock { values["service:" + service] = value }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        lock.withLock { values["user:" + service] }
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        lock.withLock { values["user:" + service] = value }
    }

    func deleteGenericPassword(service: String) throws {
        lock.withLock {
            values["service:" + service] = nil
            values["user:" + service] = nil
        }
    }
}
