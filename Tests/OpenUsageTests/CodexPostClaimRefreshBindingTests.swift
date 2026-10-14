import XCTest
@testable import OpenUsage

@MainActor
final class CodexPostClaimRefreshBindingTests: XCTestCase {
    private nonisolated static let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let expiry = instant.addingTimeInterval(3_600)

    private enum Scenario: Sendable {
        case earlierCandidate
        case changedIdentity
        case tokenRotation
    }

    private actor HTTPFixture: HTTPClient {
        let scenario: Scenario
        let noCredit: Bool
        let earlierToken: String
        let rotatedToken: String
        private var afterClaim = false
        private var didRefreshToken = false
        private var creditReads = 0
        private(set) var requests: [HTTPRequest] = []

        init(scenario: Scenario, noCredit: Bool, earlierToken: String, rotatedToken: String) {
            self.scenario = scenario
            self.noCredit = noCredit
            self.earlierToken = earlierToken
            self.rotatedToken = rotatedToken
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            requests.append(request)
            switch request.url {
            case CodexUsageClient.usageURL:
                if scenario == .earlierCandidate,
                   request.headers["Authorization"] == "Bearer \(earlierToken)", !afterClaim {
                    return Self.response("{}", status: 401)
                }
                if scenario != .earlierCandidate, afterClaim, !didRefreshToken {
                    return Self.response("{}", status: 401)
                }
                return Self.response("""
                {"rate_limit":{"primary_window":{"used_percent":\(afterClaim ? 0 : 90),"limit_window_seconds":18000,"reset_at":1800018000}}}
                """)
            case CodexUsageClient.resetCreditsURL:
                creditReads += 1
                if noCredit, creditReads == 2 { afterClaim = true }
                if afterClaim { return Self.response(#"{"credits":[],"available_count":0}"#) }
                return Self.response("""
                {"credits":[{"id":"credit-confirmed","status":"available","expires_at":\(CodexPostClaimRefreshBindingTests.expiry.timeIntervalSince1970)}],"available_count":1}
                """)
            case CodexUsageClient.consumeResetCreditURL:
                afterClaim = true
                return Self.response(#"{"code":"reset"}"#)
            case CodexUsageClient.refreshURL:
                didRefreshToken = true
                return Self.response(#"{"access_token":"\#(rotatedToken)","refresh_token":"rotated-refresh"}"#)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        private static func response(_ body: String, status: Int = 200) -> HTTPResponse {
            HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
        }
    }

    private struct Fixture {
        let store: WidgetDataStore
        let cache: ProviderSnapshotCache
        let router: CodexResetClaimRouter
        let http: HTTPFixture
        let keychain: FakeKeychain
        let confirmedToken: String
        let confirmedSource: CodexAuthState.Source
    }

    func testEarlierCandidateCannotReplaceTheConfirmedFileOrKeychainAccount() async throws {
        for useKeychain in [false, true] {
            for noCredit in [false, true] {
                let fixture = try makeFixture(scenario: .earlierCandidate, useKeychain: useKeychain, noCredit: noCredit)
                let initialOutcome = await fixture.store.refresh(providerID: "codex", force: true)
                XCTAssertEqual(initialOutcome, .refreshed)
                let original = try XCTUnwrap(fixture.store.localSnapshots["codex"])
                let binding = try XCTUnwrap(original.codexResetClaimBinding)
                XCTAssertEqual(binding.source, fixture.confirmedSource)
                let cached = fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"]
                var published: [ProviderSnapshot] = []
                fixture.store.onFreshSnapshot = { snapshot, _, _ in published.append(snapshot) }

                let service = try XCTUnwrap(fixture.router.service(for: "codex"))
                let outcome = await service.claim(
                    creditExpiringAt: Self.expiry, redeemRequestID: UUID().uuidString, binding: binding
                )

                XCTAssertEqual(outcome, noCredit ? .noCredit : .success)
                XCTAssertEqual(fixture.store.localSnapshots["codex"], original)
                XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"], cached)
                XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "confirmed-account")
                XCTAssertTrue(published.isEmpty, "another auth candidate must not reach publication callbacks")
                XCTAssertEqual(fixture.store.refreshResults["codex"]?.failure?.category, .authInvalid)
                let requests = await fixture.http.requests
                let consumes = requests.filter { $0.url == CodexUsageClient.consumeResetCreditURL }
                XCTAssertEqual(consumes.count, noCredit ? 0 : 1)
                XCTAssertTrue(consumes.allSatisfy { $0.headers["Authorization"] == "Bearer \(fixture.confirmedToken)" })
                XCTAssertEqual(requests.filter { $0.url == CodexUsageClient.usageURL }.count, 5,
                               "two initial candidates and three bounded refresh failures")
            }
        }
    }

    func testIdentityChangedByTokenRefreshCannotReplaceTheConfirmedSnapshot() async throws {
        let fixture = try makeFixture(scenario: .changedIdentity)
        _ = await fixture.store.refresh(providerID: "codex", force: true)
        let original = try XCTUnwrap(fixture.store.localSnapshots["codex"])
        let binding = try XCTUnwrap(original.codexResetClaimBinding)
        let cached = fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"]
        var published = 0
        fixture.store.onFreshSnapshot = { _, _, _ in published += 1 }

        let service = try XCTUnwrap(fixture.router.service(for: "codex"))
        let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "changed", binding: binding)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(fixture.store.localSnapshots["codex"], original)
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"], cached)
        XCTAssertEqual(published, 0)
        XCTAssertEqual(fixture.store.refreshResults["codex"]?.failure?.category, .authInvalid)
        let requests = await fixture.http.requests
        XCTAssertEqual(requests.filter { $0.url == CodexUsageClient.refreshURL }.count, 1)
        XCTAssertEqual(requests.filter { $0.url == CodexUsageClient.consumeResetCreditURL }.count, 1)
    }

    func testSameAccountTokenRotationPublishesThePostClaimUsage() async throws {
        for useKeychain in [false, true] {
            let fixture = try makeFixture(scenario: .tokenRotation, useKeychain: useKeychain)
            _ = await fixture.store.refresh(providerID: "codex", force: true)
            let original = try XCTUnwrap(fixture.store.localSnapshots["codex"])
            let binding = try XCTUnwrap(original.codexResetClaimBinding)
            var published: [ProviderSnapshot] = []
            fixture.store.onFreshSnapshot = { snapshot, _, _ in published.append(snapshot) }

            let service = try XCTUnwrap(fixture.router.service(for: "codex"))
            let outcome = await service.claim(creditExpiringAt: Self.expiry, redeemRequestID: "rotation", binding: binding)

            XCTAssertEqual(outcome, .success)
            let refreshed = try XCTUnwrap(fixture.store.localSnapshots["codex"])
            XCTAssertEqual(refreshed.codexResetClaimBinding, binding)
            XCTAssertNotEqual(refreshed.lines, original.lines)
            XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"], refreshed)
            XCTAssertEqual(published, [refreshed])
            XCTAssertEqual(fixture.store.refreshResults["codex"], .succeeded)
            let requests = await fixture.http.requests
            XCTAssertEqual(requests.filter { $0.url == CodexUsageClient.refreshURL }.count, 1)
            if useKeychain {
                let saved = try XCTUnwrap(CodexAuthStore.parseAuth(try XCTUnwrap(fixture.keychain.value)))
                XCTAssertNotEqual(saved.tokens?.accessToken, fixture.confirmedToken)
            }
        }
    }

    private func makeFixture(
        scenario: Scenario, useKeychain: Bool = false, noCredit: Bool = false
    ) throws -> Fixture {
        let earlierToken = try token(subject: "earlier-user", account: "earlier-account")
        let confirmedToken = try token(subject: "confirmed-user", account: "confirmed-account")
        let rotatedToken = try token(
            subject: scenario == .changedIdentity ? "replacement-user" : "confirmed-user",
            account: "confirmed-account", version: 2
        )
        let http = HTTPFixture(scenario: scenario, noCredit: noCredit, earlierToken: earlierToken, rotatedToken: rotatedToken)
        let files = FakeFiles()
        let keychain = FakeKeychain()
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: keychain, now: { Self.instant }
        )
        let paths = authStore.authPaths()
        let confirmedAuth = try authText(
            token: confirmedToken, account: "confirmed-account", refreshToken: scenario == .earlierCandidate ? nil : "refresh"
        )
        if scenario == .earlierCandidate {
            files.files[paths[0]] = try authText(token: earlierToken, account: "earlier-account")
        }
        let confirmedSource: CodexAuthState.Source
        if useKeychain {
            keychain.value = confirmedAuth
            confirmedSource = .keychain
        } else {
            files.files[paths[1]] = confirmedAuth
            confirmedSource = .file(path: paths[1])
        }
        let provider = CodexProvider(
            authStore: authStore, usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: UUID().uuidString, rootsOverride: []),
            includePiUsage: false, now: { Self.instant }, pricing: { .empty }
        )
        let suite = "CodexPostClaimRefreshBindingTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { Self.instant })
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([provider]), providers: [provider], cache: cache, defaults: defaults,
            now: { Self.instant }, providerIdentityKeys: ["codex": "confirmed-account"]
        )
        let router = CodexResetClaimRouter(
            providers: [provider], identityKeys: ["codex": "confirmed-account"],
            refreshAfterClaim: { cardID, binding in
                await store.refreshAfterClaim(providerID: cardID, codexBinding: binding, maxAttempts: 3, retryDelay: .zero)
            }
        )
        return Fixture(store: store, cache: cache, router: router, http: http, keychain: keychain,
                       confirmedToken: confirmedToken, confirmedSource: confirmedSource)
    }

    private func token(subject: String, account: String, version: Int = 1) throws -> String {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": subject, "version": version, "exp": Self.instant.addingTimeInterval(7_200).timeIntervalSince1970,
            "https://api.openai.com/auth": ["chatgpt_account_id": account],
        ]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }

    private func authText(token: String, account: String, refreshToken: String? = nil) throws -> String {
        String(decoding: try JSONEncoder().encode(CodexAuth(tokens: CodexTokens(
            accessToken: token, refreshToken: refreshToken, accountID: account
        ))), as: UTF8.self)
    }
}
