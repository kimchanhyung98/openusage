import Network
import XCTest
@testable import OpenUsage

final class AppDiagnosticsTests: XCTestCase {
    private var directory: URL!
    private var originalSink: LogFile!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppDiagnosticsTests." + UUID().uuidString)
        originalSink = AppLog.sink
        AppLog.sink = LogFile(directory: directory, fileName: "diagnostics.log")
        AppLog.sink.open()
        AppLog.reloadLevel(.debug)
    }

    override func tearDownWithError() throws {
        AppLog.sink = originalSink
        AppLog.reloadLevel()
        try FileManager.default.removeItem(at: directory)
    }

    private func lines() throws -> [String] {
        try String(contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    func testFailureKeepsLocalErrorIdentityAndPublishesOneSafeEvent() throws {
        let diagnostics = DiagnosticEventRecorder()
        let error = NSError(domain: "FixtureDiagnosticError", code: 17,
                            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_TOKEN_AND_ACCOUNT"])
        AppDiagnostics.failure(.resetVoteFetch, error: error, providerID: "codex@profile-private")

        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        let line = try XCTUnwrap(recorded.first)
        XCTAssertTrue(line.contains("[ERROR] [plugin:codex]"), line)
        XCTAssertTrue(line.contains("error_domain=FixtureDiagnosticError"), line)
        XCTAssertTrue(line.contains("error_code=17"), line)
        XCTAssertFalse(line.contains("PRIVATE_ERROR_TOKEN_AND_ACCOUNT"))
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.resetVoteFetch, result: .failure, category: .other, providerID: "codex")])
        let eventJSON = String(decoding: try JSONEncoder().encode(diagnostics.events), as: UTF8.self)
        for value in ["FixtureDiagnosticError", "error_code", "PRIVATE_ERROR_TOKEN_AND_ACCOUNT", "profile-private"] {
            XCTAssertFalse(eventJSON.contains(value), eventJSON)
        }
    }

    func testCorruptLocalFileFailureUsesStorageCategory() throws {
        let diagnostics = DiagnosticEventRecorder()
        AppDiagnostics.failure(.iCloudRead, error: CocoaError(.fileReadCorruptFile))

        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.iCloudRead, result: .failure, category: .storage)])
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].contains("[ERROR]"), recorded[0])
        XCTAssertTrue(recorded[0].contains("category=storage"), recorded[0])
    }

    func testLocalAPINetworkFailuresPreserveTransportCategory() throws {
        let diagnostics = DiagnosticEventRecorder()
        AppDiagnostics.failure(.localAPIListen, error: NWError.posix(.EADDRINUSE))
        AppDiagnostics.failure(.localAPIRequest, error: NWError.posix(.ENETDOWN))

        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.localAPIListen, result: .failure, category: .network),
            DiagnosticEvent(.localAPIRequest, result: .failure, category: .network)
        ])
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(recorded.allSatisfy { $0.contains("[ERROR]") && $0.contains("category=network") })
    }

    func testCocoaUserCancellationDoesNotBecomeStorageFailure() throws {
        let diagnostics = DiagnosticEventRecorder()
        let errors: [Error] = [
            CocoaError(.userCancelled),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.Code.userCancelled.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "PRIVATE_CANCELLED_OPERATION"])
        ]
        for error in errors { AppDiagnostics.failure(.iCloudRead, error: error) }

        XCTAssertTrue(try lines().isEmpty)
        XCTAssertEqual(diagnostics.events, Array(repeating: DiagnosticEvent(.iCloudRead, result: .cancelled), count: 2))
    }

    func testLocalAPITransportPeerCloseIsCancelledButTimeoutRemainsFailure() throws {
        let diagnostics = DiagnosticEventRecorder()
        LocalUsageServer.recordTransportFailure(.posix(.ECONNRESET))
        LocalUsageServer.recordTransportFailure(.posix(.EPIPE))
        LocalUsageServer.recordTransportFailure(.posix(.ETIMEDOUT))

        XCTAssertEqual(diagnostics.events, [
            DiagnosticEvent(.localAPIRequest, result: .cancelled),
            DiagnosticEvent(.localAPIRequest, result: .cancelled),
            DiagnosticEvent(.localAPIRequest, result: .failure, category: .network)
        ])
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded.allSatisfy { $0.contains("[ERROR]") && $0.contains("category=network") })
    }

    func testHTTPTransportFailureLeavesOneOperationError() async throws {
        AppLog.reloadLevel(.info)
        let diagnostics = DiagnosticEventRecorder()
        let result = await CodexResetWatchVotes.load(
            http: URLSessionHTTPClient(allowsInsecureLoopback: true),
            endpoint: URL(string: "unsupported://example.invalid/PRIVATE_REQUEST?token=PRIVATE_TOKEN")!,
            episodeID: "PRIVATE_EPISODE"
        )

        XCTAssertNil(result.percent)
        XCTAssertNotNil(result.retryNotBefore)
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1, recorded.joined(separator: "\n"))
        XCTAssertTrue(recorded.allSatisfy { $0.contains("[ERROR]") && $0.contains("operation=reset_vote_fetch") })
        XCTAssertFalse(recorded.joined().contains("PRIVATE_"))
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.resetVoteFetch, result: .failure, category: .network, providerID: "codex")])
    }

    @MainActor
    func testAntigravityTransportFailureStillEmitsOneFinalProviderError() async throws {
        AppLog.reloadLevel(.info)
        let http = RoutingHTTPClient { _ in
            throw URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_TRANSPORT_ERROR"])
        }
        let token = #"{"token":{"access_token":"PRIVATE_ACCESS","refresh_token":"PRIVATE_REFRESH","expiry":"2099-01-01T00:00:00Z"}}"#
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(keychain: FakeKeychain(token), files: FakeFiles()),
            usageClient: AntigravityUsageClient(lsHTTP: http, http: http),
            discovery: LanguageServerDiscovery(processRunner: DiagnosticEmptyProcessRunner())
        )
        let suite = "AppDiagnosticsTests.Antigravity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors),
            providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults
        )
        var reportedCategories: [ErrorCategory?] = []
        store.onRefreshOutcome = { id, outcome, category, _, _ in
            XCTAssertEqual(id, "antigravity")
            guard case .failed = outcome else { return XCTFail("Expected final provider failure") }
            reportedCategories.append(category)
        }

        _ = await store.refresh(providerID: "antigravity", force: true)

        XCTAssertGreaterThan(http.requests.count, 1)
        XCTAssertNotNil(store.providerErrors["antigravity"])
        XCTAssertEqual(reportedCategories, [.network])
        let recorded = try lines()
        let errors = recorded.filter { $0.contains("[ERROR]") }
        XCTAssertEqual(errors.count, 1, recorded.joined(separator: "\n"))
        XCTAssertTrue(errors.allSatisfy { $0.contains("[ERROR] [refresh] antigravity failed:") })
        XCTAssertFalse(recorded.joined().contains("PRIVATE_"))
    }

    @MainActor
    func testGrokOptionalPlanTransportFailureKeepsUsageAndSafeWarning() async throws {
        AppLog.reloadLevel(.info)
        let http = RoutingHTTPClient { request in
            if request.url == GrokUsageClient.settingsURL {
                throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_PLAN_ERROR"])
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
        }
        let files = FakeFiles([
            GrokAuthStore.authPath: #"{"https://auth.x.ai::client":{"key":"PRIVATE_TOKEN","expires_at":"2099-01-01T00:00:00.000Z"}}"#
        ])
        let provider = GrokProvider(
            authStore: GrokAuthStore(files: files),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(
                files: FakeFiles(), environment: FakeEnvironment(),
                homeDirectory: { URL(fileURLWithPath: "/home/none") }
            ),
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.plan)
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Weekly limit" })
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1, recorded.joined(separator: "\n"))
        XCTAssertTrue(recorded.allSatisfy { $0.contains("[WARN] [plugin:grok]") })
        XCTAssertTrue(recorded.allSatisfy { $0.contains("category=network") && $0.contains("error_code=-1001") })
        XCTAssertFalse(recorded.joined().contains("PRIVATE_"))
    }

    func testDifferentFailureCodesStayDistinguishableInLocalLog() throws {
        AppDiagnostics.failure(.resetVoteFetch, error: NSError(domain: "VotesFixture", code: 1))
        AppDiagnostics.failure(.resetVoteFetch, error: NSError(domain: "VotesFixture", code: 2))
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 2)
        XCTAssertTrue(recorded[0].contains("error_code=1"), recorded[0])
        XCTAssertTrue(recorded[1].contains("error_code=2"), recorded[1])
    }

    func testPartialFailureIsOneWarningAndOneDiagnostic() throws {
        let diagnostics = DiagnosticEventRecorder()
        AppDiagnostics.record(.cursorPlan, result: .degraded, category: .network, providerID: "cursor")
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].contains("[WARN] [plugin:cursor]"), recorded[0])
        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.cursorPlan, result: .degraded, category: .network, providerID: "cursor")])
    }

    func testExpectedFailureStaysInformationalAndCancellationDoesNotLogAnError() throws {
        let diagnostics = DiagnosticEventRecorder()
        AppDiagnostics.record(.resetCreditFetch, result: .failure, category: .notAvailable, providerID: "codex")
        AppDiagnostics.failure(.credentialRefresh, error: URLError(.cancelled), providerID: "claude@profile-private")
        let recorded = try lines()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(recorded[0].contains("[INFO]"), recorded[0])
        XCTAssertFalse(recorded[0].contains("[ERROR]"))
        XCTAssertEqual(diagnostics.events.map(\.result), [.failure, .cancelled])
    }
}

private struct DiagnosticEmptyProcessRunner: ProcessRunning {
    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}
