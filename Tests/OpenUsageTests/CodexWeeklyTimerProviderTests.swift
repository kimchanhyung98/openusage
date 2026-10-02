import XCTest
@testable import OpenUsage

@MainActor
final class CodexWeeklyTimerProviderTests: XCTestCase {
    private nonisolated static let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let path = "/timer-test/auth.json"

    func testRefreshPublishesOnlyFreshQuotaAndClearsItAfterFailure() async throws {
        let fixture = try fixture()
        let snapshot = await fixture.provider.refresh()
        let observation = try XCTUnwrap(fixture.provider.weeklyTimerObservation)
        XCTAssertEqual(observation.usedPercent, 0)
        XCTAssertEqual(observation.observedAt, snapshot.liveQuotaObservedAt)
        XCTAssertTrue(snapshot.isDegraded == true, "Reset-credit failure must preserve a valid weekly quota")

        fixture.http.response = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        let failed = await fixture.provider.refresh()
        XCTAssertNil(failed.liveQuotaObservedAt)
        XCTAssertNil(fixture.provider.weeklyTimerObservation)
    }

    func testPreparationReadsQuotaOnlyAndReturnsTheSameCredentialSource() async throws {
        let fixture = try fixture()
        let key = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: fixture.auth))
        let session = try await fixture.provider.prepareWeeklyTimerSession(expectedAccountKey: key)

        XCTAssertEqual(session.observation.usedPercent, 0)
        XCTAssertEqual(session.authState.auth, fixture.auth)
        XCTAssertEqual(session.authState.source, .file(path: Self.path))
        XCTAssertEqual(fixture.http.requests.map(\.url), [CodexUsageClient.usageURL])
        XCTAssertEqual(fixture.http.requests.first?.headers["ChatGPT-Account-Id"], "workspace")
    }

    func testPreparationRejectsChangedAccountBeforeAnyHTTPRequest() async throws {
        let fixture = try fixture()
        do {
            _ = try await fixture.provider.prepareWeeklyTimerSession(expectedAccountKey: "different-account")
            XCTFail("Account mismatch must prevent authentication and quota requests")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .accountChanged)
        }
        XCTAssertTrue(fixture.http.requests.isEmpty)
        XCTAssertNil(fixture.provider.weeklyTimerObservation)
    }

    func testFinalValidationRejectsAccountChangesAndTokenRotationsAfterPreparation() async throws {
        for changed in [try Self.auth(subject: "other"), try Self.auth(refresh: "external-rotation")] {
            let fixture = try fixture()
            let key = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: fixture.auth))
            let session = try await fixture.provider.prepareWeeklyTimerSession(expectedAccountKey: key)
            let changedText = try Self.text(changed)
            fixture.files.files[Self.path] = changedText
            do {
                try await fixture.provider.validateWeeklyTimerSession(session)
                XCTFail("Final validation must reject any changed credential generation")
            } catch {
                XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
            }
            XCTAssertEqual(fixture.files.files[Self.path], changedText)
            XCTAssertEqual(fixture.http.requests.map(\.url), [CodexUsageClient.usageURL])
        }
    }

    func testFinalValidationDoesNotFallBackToAnotherSourceAfterOriginalDisappears() async throws {
        let auth = try Self.auth()
        let text = try Self.text(auth)
        let files = FakeFiles(["~/.config/codex/auth.json": text, "~/.codex/auth.json": text])
        let keychain = FakeKeychain(text)
        let http = FakeHTTPClient(response: Self.quotaResponse)
        let provider = CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: keychain, now: { Self.instant }),
            usageClient: CodexUsageClient(http: http), now: { Self.instant }
        )
        let session = try await provider.prepareWeeklyTimerSession(expectedAccountKey: XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: auth)))
        XCTAssertEqual(session.authState.source, .file(path: "~/.config/codex/auth.json"))
        files.files.removeValue(forKey: "~/.config/codex/auth.json")

        do {
            try await provider.validateWeeklyTimerSession(session)
            XCTFail("An identical token in another source cannot replace the prepared generation")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
        }
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL])
        XCTAssertEqual(keychain.value, text)
        XCTAssertEqual(files.files["~/.codex/auth.json"], text)
    }

    func testFinalValidationAcceptsUnchangedGenerationWithoutNetworkRequests() async throws {
        let fixture = try fixture()
        let key = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: fixture.auth))
        let session = try await fixture.provider.prepareWeeklyTimerSession(expectedAccountKey: key)
        try await fixture.provider.validateWeeklyTimerSession(session)
        XCTAssertEqual(fixture.http.requests.map(\.url), [CodexUsageClient.usageURL])
    }

    func testFinalValidationRejectsTokenThatNoLongerCoversExecutionDeadline() async throws {
        let auth = try Self.auth(expiresIn: 120, refresh: nil)
        let files = FakeFiles([Self.path: try Self.text(auth)])
        let http = FakeHTTPClient(response: Self.quotaResponse)
        let provider = CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                                      scope: .home(path: "/timer-test"), now: { Self.instant }),
            usageClient: CodexUsageClient(http: http), now: { Self.instant.addingTimeInterval(61) }
        )
        let session = CodexWeeklyTimerSession(
            observation: CodexWeeklyTimerObservation(accountKey: try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: auth)),
                                                      usedPercent: 0, resetsAt: nil, observedAt: Self.instant),
            authState: CodexAuthState(auth: auth, source: .file(path: Self.path)), authStore: provider.authStore
        )
        do {
            try await provider.validateWeeklyTimerSession(session)
            XCTFail("Final validation must reject expiry within the process deadline")
        } catch {
            XCTAssertEqual(error as? CodexAuthError, .tokenExpired)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testPreparationKeepsTheSuccessfulFallbackSourceWithoutQueryingExpiredAccountAgain() async throws {
        let expired = try Self.auth(subject: "expired-account", expiresIn: 30, refresh: nil)
        let active = try Self.auth()
        let files = FakeFiles(["~/.config/codex/auth.json": try Self.text(expired), "~/.codex/auth.json": try Self.text(active)])
        let expiredHeader = "Bearer \(try XCTUnwrap(expired.tokens?.accessToken))"
        let http = RoutingHTTPClient { request in
            if request.headers["Authorization"] == expiredHeader { return HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
            return Self.quotaResponse
        }
        let provider = standardProvider(files: files, http: http)
        _ = await provider.refresh()
        let observation = try XCTUnwrap(provider.weeklyTimerObservation)
        let beforePreparation = http.requests.count

        let session = try await provider.prepareWeeklyTimerSession(expectedAccountKey: observation.accountKey)
        XCTAssertEqual(session.authState.source, .file(path: "~/.codex/auth.json"))
        XCTAssertEqual(http.requests.count, beforePreparation + 1)
        XCTAssertNotEqual(http.requests.last?.headers["Authorization"], expiredHeader)
    }

    func testPreparationRejectsChangedOrNewHigherPriorityCredentialsBeforeNetworkRequests() async throws {
        for startsWithExpiredCredential in [false, true] {
            let expired = try Self.auth(subject: "expired-account", expiresIn: 30, refresh: nil)
            let active = try Self.auth()
            let files = FakeFiles(["~/.codex/auth.json": try Self.text(active)])
            if startsWithExpiredCredential { files.files["~/.config/codex/auth.json"] = try Self.text(expired) }
            let expiredHeader = "Bearer \(try XCTUnwrap(expired.tokens?.accessToken))"
            let http = RoutingHTTPClient { request in
                if request.headers["Authorization"] == expiredHeader { return HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
                return Self.quotaResponse
            }
            let provider = standardProvider(files: files, http: http)
            _ = await provider.refresh()
            let observation = try XCTUnwrap(provider.weeklyTimerObservation)
            let beforePreparation = http.requests.count
            files.files["~/.config/codex/auth.json"] = try Self.text(Self.auth(subject: "new-account"))

            do {
                _ = try await provider.prepareWeeklyTimerSession(expectedAccountKey: observation.accountKey)
                XCTFail("Changed credential priority requires a new full provider refresh")
            } catch {
                XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
            }
            XCTAssertEqual(http.requests.count, beforePreparation)
        }
    }

    func testPreparationRejectsAuthChangedDuringQuotaRead() async throws {
        let auth = try Self.auth()
        let changed = try Self.auth(subject: "someone-else")
        let files = FakeFiles([Self.path: try Self.text(auth)])
        let changedText = try Self.text(changed)
        let http = RoutingHTTPClient { _ in
            files.files[Self.path] = changedText
            return Self.quotaResponse
        }
        let provider = makeProvider(files: files, http: http)
        do {
            _ = try await provider.prepareWeeklyTimerSession(expectedAccountKey: XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: auth)))
            XCTFail("A stale source generation must not reach execution")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
        }
        XCTAssertEqual(CodexAuthStore.parseAuth(files.files[Self.path]!)?.tokens, changed.tokens)
    }

    func testPreparationUsesExistingRefreshAndPersistsRotatedTokens() async throws {
        let original = try Self.auth(expiresIn: 120)
        let refreshed = try Self.auth(expiresIn: 3_600, refresh: "rotated-refresh")
        let files = FakeFiles([Self.path: try Self.text(original)])
        let newToken = try XCTUnwrap(refreshed.tokens?.accessToken)
        let refreshBody = try JSONSerialization.data(withJSONObject: [
            "access_token": newToken, "refresh_token": "rotated-refresh"
        ])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: refreshBody)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(newToken)")
            return Self.quotaResponse
        }
        let provider = makeProvider(files: files, http: http)
        let key = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: original))
        let session = try await provider.prepareWeeklyTimerSession(expectedAccountKey: key)
        XCTAssertEqual(session.authState.auth.tokens?.accessToken, newToken)
        XCTAssertEqual(session.authState.auth.tokens?.refreshToken, "rotated-refresh")
        XCTAssertEqual(CodexAuthStore.parseAuth(files.files[Self.path]!)?.tokens?.accessToken, newToken)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL, CodexUsageClient.usageURL])
    }

    func testPreparationDoesNotOverwriteAnExternalRotationDuringOAuthRefresh() async throws {
        let original = try Self.auth(expiresIn: 120)
        let external = try Self.auth(expiresIn: 3_600, refresh: "external-refresh")
        let files = FakeFiles([Self.path: try Self.text(original)])
        let externalText = try Self.text(external)
        let refreshBody = try JSONSerialization.data(withJSONObject: [
            "access_token": try XCTUnwrap(external.tokens?.accessToken), "refresh_token": "app-refresh"
        ])
        let http = RoutingHTTPClient { _ in
            files.files[Self.path] = externalText
            return HTTPResponse(statusCode: 200, headers: [:], body: refreshBody)
        }
        let provider = makeProvider(files: files, http: http)
        do {
            _ = try await provider.prepareWeeklyTimerSession(expectedAccountKey: XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: original)))
            XCTFail("A concurrent credential rotation must reject writeback")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
        }
        XCTAssertEqual(files.files[Self.path], externalText)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testPreparationRejectsTokenWithoutEnoughExecutionLifetime() async throws {
        let auth = try Self.auth(expiresIn: 30, refresh: nil)
        let fixture = try fixture(auth: auth)
        do {
            _ = try await fixture.provider.prepareWeeklyTimerSession(expectedAccountKey: XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: auth)))
            XCTFail("Execution needs an access token valid beyond its deadline")
        } catch {
            XCTAssertEqual(error as? CodexAuthError, .tokenExpired)
        }
        XCTAssertNil(fixture.provider.weeklyTimerObservation)
    }

    func testWritebackPreservesSourceAndRejectsChangedAuthOrIdentity() async throws {
        let fixture = try fixture()
        let original = CodexAuthState(auth: fixture.auth, source: .file(path: Self.path))
        let rotated = try Self.auth(expiresIn: 7_200, refresh: "new-refresh")
        try await fixture.provider.persistUpdatedWeeklyTimerAuth(rotated, original: original)
        XCTAssertEqual(CodexAuthStore.parseAuth(fixture.files.files[Self.path]!), rotated)

        do {
            try await fixture.provider.persistUpdatedWeeklyTimerAuth(fixture.auth, original: original)
            XCTFail("Old session generation must not overwrite refreshed credentials")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .credentialsChanged)
        }
        do {
            try await fixture.provider.persistUpdatedWeeklyTimerAuth(try Self.auth(subject: "other"), original: original)
            XCTFail("A different subject must never be written to this account")
        } catch {
            XCTAssertEqual(error as? CodexWeeklyTimerProviderError, .accountChanged)
        }
        XCTAssertEqual(CodexAuthStore.parseAuth(fixture.files.files[Self.path]!), rotated)
    }

    func testSavedAccountPreparationAndWritebackDoNotTouchSharedCredentials() async throws {
        let auth = try Self.auth()
        let keychain = ServiceKeychain(values: [CodexAuthStore.keychainService: "shared-untouched"])
        let profile = AccountProfile(id: "saved", family: "codex", label: "Saved", identityKey: "workspace", createdAt: .distantPast)
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(.init(credential: Self.text(auth), claudeOAuthAccount: nil), profile: profile)
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id), now: { Self.instant }
        )
        let provider = CodexProvider(authStore: store, usageClient: CodexUsageClient(http: FakeHTTPClient(response: Self.quotaResponse)), now: { Self.instant })
        let session = try await provider.prepareWeeklyTimerSession(expectedAccountKey: XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: auth)))
        XCTAssertEqual(session.authState.source, .accountSnapshot(profileID: profile.id))

        let rotated = try Self.auth(expiresIn: 7_200, refresh: "saved-rotated")
        try await provider.persistUpdatedWeeklyTimerAuth(rotated, original: session.authState)
        XCTAssertEqual(try store.loadAccountSnapshot(profileID: profile.id)?.auth, rotated)
        XCTAssertEqual(keychain.values[CodexAuthStore.keychainService], "shared-untouched")
    }

    func testRefreshAndPreparationSerializeTheirNetworkWork() async throws {
        let auth = try Self.auth()
        let files = FakeFiles([Self.path: try Self.text(auth)])
        let http = TimerConcurrencyHTTPClient(response: Self.quotaResponse)
        let provider = makeProvider(files: files, http: http)
        let key = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: auth))
        async let snapshot = provider.refresh()
        async let session = provider.prepareWeeklyTimerSession(expectedAccountKey: key)
        _ = try await (snapshot, session)
        let maximum = await http.maximumConcurrentRequests
        XCTAssertEqual(maximum, 1)
    }

    private func fixture(auth: CodexAuth? = nil) throws -> (provider: CodexProvider, files: FakeFiles, http: FakeHTTPClient, auth: CodexAuth) {
        let resolved = try auth ?? Self.auth()
        let files = FakeFiles([Self.path: try Self.text(resolved)])
        let http = FakeHTTPClient(response: Self.quotaResponse)
        return (makeProvider(files: files, http: http), files, http, resolved)
    }

    private func makeProvider(files: FakeFiles, http: any HTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                scope: .home(path: "/timer-test"), now: { Self.instant }
            ),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: "weekly-timer-tests", rootsOverride: []),
            includePiUsage: false, now: { Self.instant }, pricing: { .empty }
        )
    }

    private func standardProvider(files: FakeFiles, http: any HTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), now: { Self.instant }),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: "weekly-timer-fallback-tests", rootsOverride: []),
            includePiUsage: false, now: { Self.instant }, pricing: { .empty }
        )
    }

    private nonisolated static var quotaResponse: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"rate_limit":{"secondary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_at":1800604800}}}"#.utf8))
    }

    private nonisolated static func auth(subject: String = "subject", expiresIn: TimeInterval = 3_600, refresh: String? = "refresh") throws -> CodexAuth {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": subject, "exp": 1_800_000_000 + expiresIn,
            "https://api.openai.com/auth": ["chatgpt_account_id": "workspace"]
        ]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return CodexAuth(tokens: CodexTokens(accessToken: "e30.\(payload).signature", refreshToken: refresh, accountID: "workspace"))
    }

    private nonisolated static func text(_ auth: CodexAuth) throws -> String {
        String(decoding: try JSONEncoder().encode(auth), as: UTF8.self)
    }
}

private actor TimerConcurrencyHTTPClient: HTTPClient {
    var maximumConcurrentRequests = 0
    private var active = 0
    private let response: HTTPResponse

    init(response: HTTPResponse) { self.response = response }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        active += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return response
    }
}
