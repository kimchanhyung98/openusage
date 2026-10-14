import Security
import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetClaimKeychainTests: XCTestCase {
    private nonisolated static let expiry = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let credential = #"{"tokens":{"access_token":"fixture-token","account_id":"account-A"}}"#

    private func binding() throws -> CodexResetClaimBinding {
        try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(
            auth: try XCTUnwrap(CodexAuthStore.parseAuth(Self.credential)), source: .keychain
        )))
    }

    private func makeService(
        reader: SharedClaimPasswordReader,
        runner: SharedClaimProcessRunner,
        hasCredit: Bool = true,
        refreshAfterClaim: @escaping (CodexResetClaimBinding) async -> Void = { _ in }
    ) -> (CodexResetClaimService, RoutingHTTPClient) {
        let http = RoutingHTTPClient { request in
            switch request.url {
            case CodexUsageClient.resetCreditsURL:
                let body = hasCredit
                    ? """
                    {"credits":[{"id":"credit-target","status":"available","expires_at":\(Self.expiry.timeIntervalSince1970)}]}
                    """
                    : #"{"credits":[]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            case CodexUsageClient.consumeResetCreditURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
        return (CodexResetClaimService(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(),
                keychain: SecurityKeychainAccessor(
                    processRunner: runner, passwordWriter: SharedClaimPasswordWriter(reader: reader),
                    sharedPasswordWriter: SharedClaimPasswordWriter(reader: reader), appPasswordReader: reader
                )
            ),
            usageClient: CodexUsageClient(http: http), refreshAfterClaim: refreshAfterClaim
        ), http)
    }

    private func reader(value: String? = nil, deniedReads: Set<Int> = []) throws -> SharedClaimPasswordReader {
        var original: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&original), errSecSuccess)
        return SharedClaimPasswordReader(value: value ?? Self.credential, initiallyAllowed: original.boolValue, deniedReads: deniedReads)
    }

    func testSuccessfulSharedKeychainClaimUsesOneNativeReaderWithNoninteractiveRechecks() async throws {
        let reader = try reader()
        let runner = SharedClaimProcessRunner()
        var refreshes = 0
        let (service, http) = makeService(reader: reader, runner: runner, refreshAfterClaim: { _ in refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "success", binding: try binding()
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(reader.interactionRequests, [reader.initiallyAllowed, false, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(runner.callCount, 0)
    }

    func testSharedKeychainNoCreditRechecksWithoutAnotherApproval() async throws {
        let reader = try reader()
        let runner = SharedClaimProcessRunner()
        var refreshes = 0
        let (service, http) = makeService(
            reader: reader, runner: runner, hasCredit: false, refreshAfterClaim: { _ in refreshes += 1 }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "no-credit", binding: try binding()
        )

        XCTAssertEqual(outcome, .noCredit)
        XCTAssertEqual(reader.interactionRequests, [reader.initiallyAllowed, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(runner.callCount, 0)
    }

    func testSharedKeychainDenialBeforeConsumeStopsTheClaim() async throws {
        let reader = try reader(deniedReads: [2])
        let runner = SharedClaimProcessRunner()
        var refreshes = 0
        let (service, http) = makeService(reader: reader, runner: runner, refreshAfterClaim: { _ in refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "pre-consume", binding: try binding()
        )

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(reader.interactionRequests, [reader.initiallyAllowed, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(runner.callCount, 0)
    }

    func testSharedKeychainDenialAfterConsumePreservesSuccessAndSkipsRefresh() async throws {
        let reader = try reader(deniedReads: [3])
        let runner = SharedClaimProcessRunner()
        var refreshes = 0
        let (service, http) = makeService(reader: reader, runner: runner, refreshAfterClaim: { _ in refreshes += 1 })

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "post-consume", binding: try binding()
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(reader.interactionRequests, [reader.initiallyAllowed, false, false])
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(refreshes, 0)
        XCTAssertEqual(runner.callCount, 0)
    }

    func testSharedKeychainClaimRefreshAndTokenRecheckRemainNoninteractive() async throws {
        let credential = #"{"tokens":{"access_token":"fixture-token","account_id":"account-A"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        let reader = try reader(value: credential)
        let runner = SharedClaimProcessRunner()
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(),
            keychain: SecurityKeychainAccessor(
                processRunner: runner, passwordWriter: SharedClaimPasswordWriter(reader: reader),
                sharedPasswordWriter: SharedClaimPasswordWriter(reader: reader), appPasswordReader: reader
            )
        )
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(
            auth: try XCTUnwrap(CodexAuthStore.parseAuth(credential)), source: .keychain
        )))
        let http = RoutingHTTPClient { request in
            let body: String
            switch request.url {
            case CodexUsageClient.usageURL:
                body = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000}}}"#
            case CodexUsageClient.resetCreditsURL:
                body = """
                {"credits":[{"id":"credit-target","status":"available","expires_at":\(Self.expiry.timeIntervalSince1970)}]}
                """
            case CodexUsageClient.consumeResetCreditURL:
                body = #"{"code":"reset"}"#
            default:
                XCTFail("Unexpected request: \(request.url)")
                body = "{}"
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let client = CodexUsageClient(http: http)
        let provider = CodexProvider(
            authStore: authStore, usageClient: client,
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: UUID().uuidString, rootsOverride: []),
            includePiUsage: false, now: { Self.expiry }, pricing: { .empty }
        )
        let suite = "CodexResetClaimKeychainTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "account-A"]
        )
        let service = CodexResetClaimService(
            authStore: authStore, usageClient: client, refreshAfterClaim: { binding in
                await store.refreshAfterClaim(providerID: "codex", codexBinding: binding, retryDelay: .milliseconds(1))
            }
        )

        let outcome = await service.claim(
            creditExpiringAt: Self.expiry, redeemRequestID: "refresh", binding: binding
        )

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(reader.interactionRequests, [reader.initiallyAllowed, false, false, false, false])
        XCTAssertEqual(runner.callCount, 0)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST", "GET", "GET"])
        XCTAssertEqual(store.localSnapshots["codex"]?.codexResetClaimBinding, binding)
        XCTAssertNil(store.refreshResults["codex"]?.failure)
    }

    func testNoninteractiveKeychainRotationKeepsItsReaderAcrossSaves() async throws {
        let original = "\n" + #"{"future_field":true,"tokens":{"access_token":"old","account_id":"account-A"}}"# + "\n"
        let reader = try reader(value: original)
        let runner = SharedClaimProcessRunner()
        let authStore = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(),
            keychain: SecurityKeychainAccessor(
                processRunner: runner, passwordWriter: SharedClaimPasswordWriter(reader: reader),
                sharedPasswordWriter: SharedClaimPasswordWriter(reader: reader), appPasswordReader: reader
            )
        )

        let saved = try await loadOffMainActor {
            var state = try XCTUnwrap(authStore.loadKeychainAuth(allowInteraction: false))
            state.auth.tokens?.accessToken = "first-rotation"
            state = try authStore.save(state, allowInteraction: false)
            state.auth.tokens?.accessToken = "second-rotation"
            return try authStore.save(state, allowInteraction: false)
        }

        XCTAssertEqual(saved.auth.tokens?.accessToken, "second-rotation")
        XCTAssertEqual(CodexAuthStore.parseAuth(reader.currentValue)?.tokens?.accessToken, "second-rotation")
        let document = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(reader.currentValue))
        XCTAssertEqual(document["future_field"] as? Bool, true)
        XCTAssertEqual(reader.interactionRequests, [false, false, false])
        XCTAssertEqual(runner.callCount, 0)
    }
}

private final class SharedClaimPasswordReader: GenericPasswordReading, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    let initiallyAllowed: Bool
    private let deniedReads: Set<Int>
    private var reads: [Bool] = []

    init(value: String, initiallyAllowed: Bool, deniedReads: Set<Int>) {
        self.value = value
        self.initiallyAllowed = initiallyAllowed
        self.deniedReads = deniedReads
    }

    var interactionRequests: [Bool] { lock.withLock { reads } }
    var currentValue: String { lock.withLock { value } }

    func replace(_ value: String) { lock.withLock { self.value = value } }

    func read(service: String, account: String?) throws -> String? {
        XCTAssertFalse(Thread.isMainThread, "Credential reads must not block the main thread")
        XCTAssertEqual(service, CodexAuthStore.keychainService)
        XCTAssertNil(account)
        var allowed: DarwinBoolean = false
        XCTAssertEqual(SecKeychainGetUserInteractionAllowed(&allowed), errSecSuccess)
        return try lock.withLock {
            reads.append(allowed.boolValue)
            if deniedReads.contains(reads.count) {
                throw KeychainError.readFailed("Shared credential requires Keychain access.")
            }
            return value
        }
    }
}

private struct SharedClaimPasswordWriter: GenericPasswordWriting {
    let reader: SharedClaimPasswordReader

    func write(service: String, account: String?, value: Data) throws {
        XCTAssertEqual(service, CodexAuthStore.keychainService)
        XCTAssertNil(account)
        reader.replace(String(decoding: value, as: UTF8.self))
    }
}

private final class SharedClaimProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        lock.withLock { calls += 1 }
        throw KeychainError.readFailed("Interactive subprocess must not be launched during a claim.")
    }
}
