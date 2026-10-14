import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialSourceBindingTests: XCTestCase {
    private static let home = URL(fileURLWithPath: "/Users/source-binding-test")

    func testObserverDoesNotAttributeUnknownFirstCredentialToNamedSecondFile() {
        let observer = makeObserver(
            first: #"{"tokens":{"access_token":"unknown-first-token"}}"#,
            second: auth(token: "known-second-token", accountID: "second-account")
        )

        guard case .unresolved = observer.observeCodex() else {
            return XCTFail("The first usable credential has no identity; the second file must not name its account")
        }
    }

    func testObserverDoesNotSkipAPIKeyOnlyFirstCredentialToNamedSecondFile() {
        let observer = makeObserver(
            first: #"{"OPENAI_API_KEY":"first-api-key"}"#,
            second: auth(token: "known-second-token", accountID: "second-account")
        )

        guard case .unresolved = observer.observeCodex() else {
            return XCTFail("The provider stops at API-key authentication; a later account must not be attributed")
        }
    }

    func testObserverSkipsMalformedOrTokenlessFilesBeforeNamedCredential() {
        for first in [
            "not-json",
            #"{"tokens":{"account_id":"tokenless-account"}}"#,
            #"{"tokens":{"access_token":"","account_id":"empty-token-account"}}"#,
        ] {
            let observer = makeObserver(
                first: first,
                second: auth(token: "known-second-token", accountID: "second-account")
            )

            XCTAssertEqual(
                observer.observeCodex(),
                .resolved(identityKey: "second-account", label: nil, anchor: Self.home.path + "/.codex"),
                "Only credentials the provider can attempt should stop source selection"
            )
        }
    }

    func testUnresolvedFirstCredentialCanFallBackAfter401WithoutAccountStamp() async {
        let files = CodexBindingFiles([
            "~/.config/codex/auth.json": CodexBindingTestFixture.auth(token: "unknown-first"),
            "~/.codex/auth.json": auth(token: "known-second", accountID: "second-account"),
        ])
        let keychain = CodexBindingKeychain()
        let assembly = makeAssembly(files: files, keychain: keychain)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL { return CodexBindingTestFixture.resetCredits }
            if request.headers["Authorization"] == "Bearer unknown-first" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return CodexBindingTestFixture.quota(used: 77)
        }
        let provider = CodexBindingTestFixture.provider(
            files: files, keychain: keychain, binding: assembly.codexDefaultAccountBinding, http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(assembly.identityKeysByCard["codex"])
        XCTAssertNil(assembly.codexDefaultAccountBinding)
        XCTAssertEqual(provider.authStore.scope, .standard)
        assertSession(snapshot, used: 77)
        let requests = http.requests.filter { $0.url == CodexUsageClient.usageURL }
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["Bearer unknown-first", "Bearer known-second"])
        XCTAssertEqual(requests.last?.headers["ChatGPT-Account-Id"], "second-account")
    }

    func testCodexHomeBindingIgnoresOtherHomes() async throws {
        let overrideHome = "/custom-codex"
        let environment = ["CODEX_HOME": "  \(overrideHome)\n"]
        let files = CodexBindingFiles([
            overrideHome + "/auth.json": auth(token: "override-token", accountID: "override-account"),
            "~/.config/codex/auth.json": auth(token: "config-token", accountID: "config-account"),
            "~/.codex/auth.json": auth(token: "default-token", accountID: "default-account"),
        ])
        let keychain = CodexBindingKeychain()
        let assembly = makeAssembly(files: files, keychain: keychain, environment: environment)
        let binding = try XCTUnwrap(assembly.codexDefaultAccountBinding)
        let http = successfulHTTP()
        let provider = CodexBindingTestFixture.provider(
            files: files, keychain: keychain, environment: environment, binding: binding, http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(binding.home, overrideHome)
        XCTAssertEqual(binding.identityKey, "override-account")
        assertSession(snapshot, used: 25)
        XCTAssertEqual(
            http.requests.filter { $0.url == CodexUsageClient.usageURL }.map { $0.headers["Authorization"] },
            ["Bearer override-token"]
        )
        XCTAssertTrue(keychain.readServices.isEmpty)
    }

    func testManagedBindingIgnoresEnvironmentLegacyAndKeychain() async throws {
        let environment = ["CODEX_HOME": "/other-codex"]
        let files = CodexBindingFiles([
            "~/.codex/auth.json": auth(token: "managed-token", accountID: "managed-account"),
            "~/.config/codex/auth.json": auth(token: "legacy-token", accountID: "legacy-account"),
            "/other-codex/auth.json": auth(token: "environment-token", accountID: "environment-account"),
        ])
        let keychain = CodexBindingKeychain(
            value: auth(token: "keychain-token", accountID: "keychain-account"), presence: true
        )
        let assembly = makeAssembly(files: files, keychain: keychain, environment: environment, pinned: true)
        let binding = try XCTUnwrap(assembly.codexDefaultAccountBinding)
        let http = successfulHTTP()
        let provider = CodexBindingTestFixture.provider(
            files: files, keychain: keychain, environment: environment, binding: binding, http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(binding.home, Self.home.path + "/.codex")
        XCTAssertEqual(binding.identityKey, "managed-account")
        assertSession(snapshot, used: 25)
        XCTAssertEqual(
            http.requests.filter { $0.url == CodexUsageClient.usageURL }.map { $0.headers["Authorization"] },
            ["Bearer managed-token"]
        )
        XCTAssertTrue(keychain.probeServices.isEmpty)
        XCTAssertTrue(keychain.readServices.isEmpty)
    }

    func testLegacyKeychainPresenceKeepsFallbackUnboundWithoutObserverSecretRead() async {
        let files = CodexBindingFiles([
            "~/.codex/auth.json": auth(token: "expired-file", accountID: "file-account"),
        ])
        let keychain = CodexBindingKeychain(
            value: auth(token: "keychain-token", accountID: "keychain-account"), presence: true
        )
        let assembly = makeAssembly(files: files, keychain: keychain)
        XCTAssertNil(assembly.identityKeysByCard["codex"])
        XCTAssertNil(assembly.codexDefaultAccountBinding)
        XCTAssertEqual(keychain.probeServices, [CodexAuthStore.keychainService])
        XCTAssertTrue(keychain.readServices.isEmpty)
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.resetCreditsURL { return CodexBindingTestFixture.resetCredits }
            if request.headers["Authorization"] == "Bearer expired-file" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return CodexBindingTestFixture.quota(used: 63)
        }
        let provider = CodexBindingTestFixture.provider(
            files: files, keychain: keychain, binding: assembly.codexDefaultAccountBinding, http: http
        )

        let snapshot = await provider.refresh()

        assertSession(snapshot, used: 63)
        XCTAssertEqual(
            http.requests.filter { $0.url == CodexUsageClient.usageURL }.map { $0.headers["Authorization"] },
            ["Bearer expired-file", "Bearer keychain-token"]
        )
        XCTAssertEqual(keychain.readServices, [CodexAuthStore.keychainService])
    }

    func testUnverifiableLegacyKeychainDoesNotProduceFileIdentityBinding() {
        let files = CodexBindingFiles([
            "~/.codex/auth.json": auth(token: "file-token", accountID: "file-account"),
        ])
        let keychain = CodexBindingKeychain(presence: nil)

        let assembly = makeAssembly(files: files, keychain: keychain)

        XCTAssertNil(assembly.identityKeysByCard["codex"])
        XCTAssertNil(assembly.codexDefaultAccountBinding)
        XCTAssertEqual(keychain.probeServices, [CodexAuthStore.keychainService])
        XCTAssertTrue(keychain.readServices.isEmpty)
    }

    private func makeObserver(first: String, second: String) -> DefaultAccountObserver {
        let files = FakeFiles([
            Self.home.path + "/.config/codex/auth.json": first,
            Self.home.path + "/.codex/auth.json": second,
            "~/.config/codex/auth.json": first,
            "~/.codex/auth.json": second,
        ])
        return DefaultAccountObserver(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            homeDirectory: { [home = Self.home] in home }
        )
    }

    private func makeAssembly(
        files: CodexBindingFiles, keychain: CodexBindingKeychain,
        environment: [String: String] = [:], pinned: Bool = false
    ) -> ProviderAccountAssembly {
        let suite = "CodexCredentialSourceBindingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(environment), files: files, keychain: keychain,
            homeDirectory: { [home = Self.home] in home }, pinsCodexSharedHome: pinned
        )
        return ProviderAccountAssembly.make(
            observer: observer, accountsStore: ProviderAccountsStore(defaults: defaults), families: ["codex"],
            codexSharedAuthHome: pinned ? Self.home.path + "/.codex" : nil
        )
    }

    private func successfulHTTP() -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            request.url == CodexUsageClient.resetCreditsURL
                ? CodexBindingTestFixture.resetCredits : CodexBindingTestFixture.quota()
        }
    }

    private func assertSession(
        _ snapshot: ProviderSnapshot, used expected: Double,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(snapshot.errorCategory, file: file, line: line)
        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("Expected a successful Session quota", file: file, line: line)
        }
        XCTAssertEqual(used, expected, file: file, line: line)
    }

    private func auth(token: String, accountID: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }
}
