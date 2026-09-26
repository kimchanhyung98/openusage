import XCTest
@testable import OpenUsage

@MainActor
final class AccountSnapshotUsageTests: XCTestCase {
    func testManualReconciliationCanApproveTheSelectedSnapshot() async throws {
        for hasInterruptedReplacement in [false, true] {
            let keychain = SnapshotUsageKeychain()
            let suite = "AccountReconciliationApproval-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            defer {
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: home)
            }
            let store = AccountProfilesStore(defaults: defaults)
            let profile = try store.add(family: "claude", label: "Saved", identityKey: "previous|org")
            if hasInterruptedReplacement {
                _ = try store.beginIdentityReplacement(
                    profileID: profile.id, with: "saved|org", replacesSharedAuthentication: false
                )
            }
            try AccountCredentialVault(keychain: keychain).save(.init(
                credential: #"{"claudeAiOauth":{"accessToken":"token"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"saved","organizationUuid":"org"}"#
            ), profile: profile)
            keychain.requiresInteraction = true
            keychain.assertBackgroundReads = true
            let importer = AccountCredentialImporter(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: home,
                workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
            )
            do {
                _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)
                XCTFail("Automatic reconciliation must not request approval")
            } catch {
                XCTAssertEqual(error.localizedDescription, SnapshotUsageKeychain.approvalError.localizedDescription)
            }
            XCTAssertEqual(try store.pendingIdentityReplacement() != nil, hasInterruptedReplacement)
            let result = try await ProviderRefreshContext.$isManual.withValue(true) {
                try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)
            }
            XCTAssertEqual(result, .noUsableAuthentication)
            XCTAssertEqual(keychain.interactionRequests, hasInterruptedReplacement ? [false, true, true] : [false, true])
            XCTAssertNil(try store.pendingIdentityReplacement())
            XCTAssertEqual(store.profile(id: profile.id)?.identityKey,
                           hasInterruptedReplacement ? "saved|org" : "previous|org")
            if hasInterruptedReplacement {
                keychain.assertBackgroundReads = false
                try AccountCredentialVault(keychain: keychain).save(.init(
                    credential: #"{"claudeAiOauth":{"accessToken":"re-signed-token"}}"#,
                    claudeOAuthAccount: #"{"accountUuid":"re-signed","organizationUuid":"org"}"#
                ), profile: profile)
                _ = try store.beginIdentityReplacement(
                    profileID: profile.id, with: "re-signed|org", replacesSharedAuthentication: false
                )
                keychain.interactionRequests = []
                let reauthenticated = try importer.completeReSignIn(profileID: profile.id, in: store, isActive: false)
                XCTAssertEqual(reauthenticated.identityKey, "re-signed|org")
                XCTAssertFalse(keychain.interactionRequests.isEmpty)
                XCTAssertTrue(keychain.interactionRequests.allSatisfy { $0 })
                XCTAssertNil(try store.pendingIdentityReplacement())
            }
        }
    }

    func testCodexCredentialDetectionChecksPresenceWithoutReadingSecrets() async throws {
        let keychain = SnapshotUsageKeychain()
        let profile = profile(id: "detection", family: "codex")
        try AccountCredentialVault(keychain: keychain).save(.init(
            credential: #"{"tokens":{"access_token":"token","account_id":"personal"}}"#,
            claudeOAuthAccount: nil
        ), profile: profile)
        keychain.assertBackgroundReads = true
        keychain.requiresInteraction = true
        let runtime = CodexProvider(authStore: CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        ))

        let detected = await runtime.hasLocalCredentials()

        XCTAssertTrue(detected)
        XCTAssertTrue(keychain.interactionRequests.isEmpty)
    }

    func testRegisteredSnapshotsRemainAvailableWhenPresenceIsUnknown() async {
        let profile = profile(id: "presence", family: "claude")
        for presence in [true, false, nil] as [Bool?] {
            let keychain = SnapshotPresenceKeychain(presence: presence)
            XCTAssertEqual(AccountCredentialVault(keychain: keychain).contains(profile: profile), presence != false)
            XCTAssertEqual(ClaudeAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                scope: .accountSnapshot(profileID: profile.id)
            ).hasCredentialFootprint(), presence != false)
            let codex = CodexProvider(authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                scope: .accountSnapshot(profileID: profile.id)
            ))
            let detected = await codex.hasLocalCredentials()
            XCTAssertEqual(detected, presence != false)
        }
    }

    func testResetClaimCanApproveSavedCredentialsOffMainThreadAndStopsOnReadFailure() async throws {
        let validCredential = #"{"tokens":{"access_token":"token","account_id":"personal"}}"#
        let scenarios: [(KeychainError?, ErrorCategory)] = [
            (nil, .notAvailable),
            (SnapshotUsageKeychain.approvalError, .credentialAccess),
            (nil, .authInvalid),
        ]
        for (failure, category) in scenarios {
            let diagnostics = DiagnosticEventRecorder()
            let keychain = SnapshotUsageKeychain()
            let profile = profile(id: "claim", family: "codex")
            try AccountCredentialVault(keychain: keychain).save(.init(
                credential: validCredential,
                claudeOAuthAccount: nil
            ), profile: profile)
            if category == .authInvalid {
                keychain.currentUserValues[AccountCredentialVault.service(family: "codex", profileID: profile.id)] = "invalid-json"
            }
            keychain.requiresInteraction = true
            keychain.assertBackgroundReads = true
            keychain.readError = failure
            let http = FakeHTTPClient(response: HTTPResponse(
                statusCode: 200, headers: [:], body: Data(#"{"credits":[]}"#.utf8)
            ))
            let service = CodexResetClaimService(
                authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                         scope: .accountSnapshot(profileID: profile.id)),
                usageClient: CodexUsageClient(http: http), refreshAfterClaim: {}
            )

            let outcome = await service.claim(creditExpiringAt: Date(), redeemRequestID: "fixture")

            let readSucceeded = category == .notAvailable
            XCTAssertEqual(outcome, readSucceeded ? .noCredit : .failed)
            XCTAssertEqual(keychain.interactionRequests, [true])
            XCTAssertEqual(http.requests.count, readSucceeded ? 1 : 0)
            XCTAssertTrue(http.requests.allSatisfy { $0.method == "GET" })
            XCTAssertEqual(diagnostics.events.filter { $0.operation == .resetClaim }, [
                DiagnosticEvent(.resetClaim, result: readSucceeded ? .success : .failure,
                                category: category, providerID: "codex")
            ])
        }
    }

    func testUnknownPresenceDoesNotDetectAnUnregisteredClaudeLogin() {
        let authStore = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(),
            keychain: SnapshotPresenceKeychain(presence: nil),
            scope: .configDir(path: "/unused-claude", keychainLiteral: "/unused-claude")
        )

        XCTAssertFalse(authStore.hasCredentialFootprint())
    }

    func testClaudeSnapshotScopeReadsOnlyTheSavedProfileCredential() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "claude-default-home", family: "claude")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"personal-token"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        keychain.currentUserValues[ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))]
            = #"{"claudeAiOauth":{"accessToken":"work-token"}}"#

        let candidates = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        ).loadCredentialCandidates()

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["personal-token"])
        XCTAssertEqual(candidates.map(\.source), [.accountSnapshot(profileID: profile.id)])
    }

    func testCodexSnapshotScopeReadsOnlyTheSavedProfileCredential() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "codex-default-home", family: "codex")
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: #"{"tokens":{"access_token":"personal-token","account_id":"personal"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        keychain.values[CodexAuthStore.keychainService]
            = #"{"tokens":{"access_token":"work-token","account_id":"work"}}"#

        let candidates = CodexAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        ).loadAuthCandidates()

        XCTAssertEqual(candidates.map(\.auth.tokens?.accessToken), ["personal-token"])
        XCTAssertEqual(candidates.map(\.source), [.accountSnapshot(profileID: profile.id)])
    }

    func testCatalogBuildsReadOnlyRuntimesForSnapshotCards() {
        let cards = [
            AccountUsageSnapshotCard(
                id: "claude@profile-claude-default-home",
                profileID: "claude-default-home",
                family: "claude"
            ),
            AccountUsageSnapshotCard(
                id: "codex@profile-codex-default-home",
                profileID: "codex-default-home",
                family: "codex"
            )
        ]

        let runtimes = ProviderCatalog.make(snapshotCards: cards)

        let claude = runtimes.compactMap { $0 as? ClaudeProvider }
            .first { $0.provider.id == cards[0].id }
        let codex = runtimes.compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == cards[1].id }
        XCTAssertEqual(claude?.authStore.scope, .accountSnapshot(profileID: "claude-default-home"))
        XCTAssertEqual(codex?.authStore.scope, .accountSnapshot(profileID: "codex-default-home"))
    }

    func testClaudeTokenRotationPersistsBackToTheSameSnapshot() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "claude-default-home", family: "claude")
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(
                credential: #"{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"refresh"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"personal"}"#
            ),
            profile: profile
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        )
        let generation = try store.credentialGeneration()
        var state = try XCTUnwrap(store.loadCredentialCandidates().first)
        state.oauth.accessToken = "new-token"

        XCTAssertTrue(try store.save(state, ifUnchanged: generation))
        let entry = try XCTUnwrap(vault.load(profile: profile))
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(entry.credential)?.claudeAiOauth?.accessToken, "new-token")
        XCTAssertEqual(entry.claudeOAuthAccount, #"{"accountUuid":"personal"}"#)
    }

    func testCodexTokenRotationPersistsBackToTheSameSnapshot() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "codex-default-home", family: "codex")
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(
                credential: #"{"tokens":{"access_token":"old-token","refresh_token":"refresh","account_id":"personal"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )
        let store = CodexAuthStore(
            environment: FakeEnvironment([:]),
            keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id)
        )
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.auth.tokens?.accessToken = "new-token"

        try store.save(state)
        let entry = try XCTUnwrap(vault.load(profile: profile))
        XCTAssertEqual(CodexAuthStore.parseAuth(entry.credential)?.tokens?.accessToken, "new-token")
    }

    func testRemovingAnAccountDeletesItsCredentialSnapshot() throws {
        let keychain = SnapshotUsageKeychain()
        let profile = self.profile(id: "codex-work", family: "codex")
        let vault = AccountCredentialVault(keychain: keychain)
        try vault.save(
            .init(
                credential: #"{"tokens":{"access_token":"work-token","account_id":"work"}}"#,
                claudeOAuthAccount: nil
            ),
            profile: profile
        )

        try AccountCredentialSnapshotRemover(keychain: keychain).remove(profile: profile)

        XCTAssertNil(try vault.load(profile: profile))
    }

    func testAccountRefreshOnlyRequestsApprovalForManualRefreshAndPreservesReadErrors() async {
        for family in ["claude", "codex"] {
            let keychain = SnapshotUsageKeychain()
            let failure = KeychainError.readFailed("Saved account requires Keychain access.")
            keychain.readError = failure
            let runtime: any ProviderRuntime
            if family == "claude" {
                runtime = ClaudeProvider(authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                    scope: .accountSnapshot(profileID: "fixture")
                ))
            } else {
                runtime = CodexProvider(authStore: CodexAuthStore(
                    environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                    scope: .accountSnapshot(profileID: "fixture")
                ))
            }

            for isManual in [false, true, false] {
                let snapshot = await ProviderRefreshContext.$isManual.withValue(isManual) {
                    await runtime.refresh()
                }
                guard case .badge(_, let message, _, _) = snapshot.lines.first else {
                    XCTFail("Expected a Keychain access error for \(family)")
                    continue
                }
                XCTAssertEqual(message, failure.localizedDescription, family)
                XCTAssertEqual(snapshot.errorCategory, .credentialAccess, family)
            }
            XCTAssertEqual(keychain.interactionRequests, [false, true, false], family)
        }
    }

    func testManualRefreshKeepsApprovalThroughTokenRotationAndGenerationChecks() async throws {
        for family in ["claude", "codex"] {
            let keychain = SnapshotUsageKeychain()
            let profile = profile(id: "rotation", family: family)
            let vault = AccountCredentialVault(keychain: keychain)
            let credential = family == "claude"
                ? #"{"claudeAiOauth":{"accessToken":"old-token","refreshToken":"old-refresh","expiresAt":1}}"#
                : #"{"tokens":{"access_token":"old-token","refresh_token":"old-refresh"},"last_refresh":"2000-01-01T00:00:00Z"}"#
            try vault.save(.init(credential: credential, claudeOAuthAccount: "metadata"), profile: profile)
            keychain.requiresInteraction = true
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600,"five_hour":{"utilization":12},"rate_limit":{"primary_window":{"used_percent":12}}}"#.utf8
            )))
            let runtime = runtime(family: family, keychain: keychain, http: http, profileID: profile.id)

            _ = await ProviderRefreshContext.$isManual.withValue(true) { await runtime.refresh() }

            XCTAssertTrue(keychain.interactionRequests.allSatisfy { $0 }, family)
            keychain.requiresInteraction = false
            let saved = try XCTUnwrap(vault.load(profile: profile))
            XCTAssertTrue(saved.credential.contains("new-refresh"), family)
            XCTAssertEqual(saved.claudeOAuthAccount, "metadata", family)
        }
    }

    func testReloadReadFailureIsPreservedWithoutUsingStaleCredentials() async throws {
        for family in ["claude", "codex"] {
            let keychain = SnapshotUsageKeychain()
            let profile = profile(id: "reload", family: family)
            let credential = family == "claude"
                ? #"{"claudeAiOauth":{"accessToken":"token"}}"#
                : #"{"tokens":{"access_token":"token","refresh_token":"refresh"},"last_refresh":"2000-01-01T00:00:00Z"}"#
            try AccountCredentialVault(keychain: keychain).save(
                .init(credential: credential, claudeOAuthAccount: nil), profile: profile
            )
            keychain.failAfterRead = 1
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8)))
            let runtime = runtime(family: family, keychain: keychain, http: http, profileID: profile.id)

            let snapshot = await ProviderRefreshContext.$isManual.withValue(true) { await runtime.refresh() }

            guard case .badge(_, let message, _, _) = snapshot.lines.first else {
                XCTFail("Expected a read failure for \(family)")
                continue
            }
            XCTAssertEqual(message, SnapshotUsageKeychain.approvalError.localizedDescription, family)
            if family == "codex" { XCTAssertTrue(http.requests.isEmpty) }
        }
    }

    func testCorruptSnapshotReportsActionableError() async {
        for family in ["claude", "codex"] {
            let keychain = SnapshotUsageKeychain()
            keychain.currentUserValues[AccountCredentialVault.service(family: family, profileID: "corrupt")] = "invalid-json"
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
            let snapshot = await runtime(family: family, keychain: keychain, http: http, profileID: "corrupt").refresh()

            guard case .badge(_, let message, _, _) = snapshot.lines.first else {
                XCTFail("Expected a corrupt snapshot error")
                continue
            }
            XCTAssertTrue(message.contains("Sign in again"), family)
            XCTAssertEqual(snapshot.errorCategory, .authInvalid, family)
            XCTAssertFalse(message.contains("AccountCredentialVaultError"), family)
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    private func runtime(
        family: String, keychain: SnapshotUsageKeychain, http: FakeHTTPClient, profileID: String
    ) -> any ProviderRuntime {
        if family == "claude" {
            return ClaudeProvider(
                authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                           scope: .accountSnapshot(profileID: profileID)),
                usageClient: ClaudeUsageClient(httpClient: http),
                logUsageScanner: ClaudeLogUsageScanner(cacheIdentityOverride: "snapshot-review", rootsOverride: []),
                includePiUsage: false, pricing: { .empty }
            )
        }
        return CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                      scope: .accountSnapshot(profileID: profileID)),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: "snapshot-review", rootsOverride: []),
            includePiUsage: false, pricing: { .empty }
        )
    }

    private func profile(id: String, family: String) -> AccountProfile {
        AccountProfile(
            id: id,
            family: family,
            label: "Account 1",
            identityKey: "personal",
            createdAt: .distantPast
        )
    }
}

private final class SnapshotUsageKeychain: KeychainAccessing, @unchecked Sendable {
    static let approvalError = KeychainError.readFailed("Saved account requires Keychain access.")
    var values: [String: String] = [:]
    var currentUserValues: [String: String] = [:]
    var readError: KeychainError?
    var interactionRequests: [Bool] = []
    var requiresInteraction = false
    var failAfterRead: Int?
    var assertBackgroundReads = false

    func genericPasswordExists(service: String) -> Bool? {
        if assertBackgroundReads { XCTAssertFalse(Thread.isMainThread) }
        return currentUserValues[service] != nil || values[service] != nil
    }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        if assertBackgroundReads { XCTAssertFalse(Thread.isMainThread, "Credential probe blocked the main thread") }
        interactionRequests.append(allowInteraction)
        if let readError { throw readError }
        if requiresInteraction && !allowInteraction { throw Self.approvalError }
        if let failAfterRead, interactionRequests.count > failAfterRead { throw Self.approvalError }
        return forCurrentUser ? currentUserValues[service] : values[service]
    }

    func readGenericPassword(service: String) throws -> String? { values[service] }
    func writeGenericPassword(service: String, value: String) throws { values[service] = value }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { currentUserValues[service] }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        currentUserValues[service] = value
    }
    func deleteGenericPassword(service: String) throws {
        values.removeValue(forKey: service)
        currentUserValues.removeValue(forKey: service)
    }
}

private struct SnapshotPresenceKeychain: KeychainAccessing {
    var presence: Bool?

    func genericPasswordExists(service: String) -> Bool? { presence }
    func readGenericPassword(service: String) throws -> String? {
        XCTFail("Presence checks must not read secrets")
        return nil
    }
    func writeGenericPassword(service: String, value: String) throws {}
    func deleteGenericPassword(service: String) throws {}
}
