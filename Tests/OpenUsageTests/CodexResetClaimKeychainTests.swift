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
                keychain: SecurityKeychainAccessor(processRunner: runner, appPasswordReader: reader)
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
            keychain: SecurityKeychainAccessor(processRunner: runner, appPasswordReader: reader)
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
}

private final class SharedClaimPasswordReader: GenericPasswordReading, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String
    let initiallyAllowed: Bool
    private let deniedReads: Set<Int>
    private var reads: [Bool] = []

    init(value: String, initiallyAllowed: Bool, deniedReads: Set<Int>) {
        self.value = value
        self.initiallyAllowed = initiallyAllowed
        self.deniedReads = deniedReads
    }

    var interactionRequests: [Bool] { lock.withLock { reads } }

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
