import XCTest
@testable import OpenUsage

@MainActor
final class CredentialRefreshDiagnosticsTests: XCTestCase {
    func testTokenEndpointFailuresAreRecordedOncePerAttempt() async {
        for kind in Kind.allCases {
            let events = DiagnosticEventRecorder()
            let fixture = fixture(kind, expired: false) { _ in
                HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }

            _ = await fixture.provider.refresh()

            XCTAssertEqual(fixture.refreshRequests.count, 1, kind.rawValue)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, [
                DiagnosticEvent(.credentialRefresh, result: .failure, category: .http5xx, providerID: kind.rawValue)
            ], kind.rawValue)
            XCTAssertFalse(events.events.contains { $0.operation == .credentialSave }, kind.rawValue)
        }
    }

    func testMalformedTokenResponsesAreRecordedBeforeExistingFailureFallback() async throws {
        for kind in Kind.allCases {
            let events = DiagnosticEventRecorder()
            let fixture = fixture(kind, expired: false) { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8))
            }

            let (_, logs) = try await captureLogs { await fixture.provider.refresh() }

            XCTAssertEqual(fixture.refreshRequests.count, 1, kind.rawValue)
            XCTAssertEqual(logs.split(separator: "\n").filter { $0.contains("[WARN]") || $0.contains("[ERROR]") }.count, 1, logs)
            XCTAssertFalse(logs.contains("not-json"), logs)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, [
                DiagnosticEvent(.credentialRefresh, result: .failure,
                                category: kind == .codex ? .authExpired : .decoding, providerID: kind.rawValue)
            ], kind.rawValue)
            XCTAssertFalse(events.events.contains { $0.operation == .credentialSave }, kind.rawValue)
        }
    }

    func testCursorPreflightAndAuthRetryCountTwoActualRefreshAttempts() async {
        let events = DiagnosticEventRecorder()
        let fixture = fixture(.cursor) { _ in
            HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }

        _ = await fixture.provider.refresh()

        XCTAssertEqual(fixture.refreshRequests.count, 2)
        XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, Array(repeating:
            DiagnosticEvent(.credentialRefresh, result: .failure, category: .http5xx, providerID: "cursor"), count: 2
        ))
    }

    func testCursorRejectedTokenPayloadPreservesExistingAuthOutcome() async {
        let cases: [(String, ErrorCategory, CursorAuthError)] = [
            (#"{"shouldLogout":true}"#, .authExpired, .sessionExpired),
            (#"{}"#, .decoding, .tokenExpired),
            (#"{"access_token":"   "}"#, .decoding, .tokenExpired)
        ]
        for (body, category, expectedError) in cases {
            let diagnostics = DiagnosticEventRecorder()
            let fixture = fixture(.cursor, expired: false) { _ in
                HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }

            let snapshot = await fixture.provider.refresh()

            XCTAssertEqual(fixture.refreshRequests.count, 1)
            XCTAssertEqual(snapshot.lines, ProviderSnapshot.error(provider: fixture.provider.provider, error: expectedError).lines)
            XCTAssertEqual(diagnostics.events.filter { $0.operation == .credentialRefresh }, [
                DiagnosticEvent(.credentialRefresh, result: .failure, category: category, providerID: "cursor")
            ])
            XCTAssertFalse(diagnostics.events.contains { $0.operation == .credentialSave })
        }
    }

    func testTransportFailuresKeepOriginalCategoryBeforeAuthRetryMapsError() async {
        for kind in Kind.allCases {
            let events = DiagnosticEventRecorder()
            let fixture = fixture(kind, expired: false) { _ in throw URLError(.timedOut) }

            _ = await fixture.provider.refresh()

            XCTAssertEqual(fixture.refreshRequests.count, 1, kind.rawValue)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, [
                DiagnosticEvent(.credentialRefresh, result: .failure, category: .network, providerID: kind.rawValue)
            ], kind.rawValue)
        }
    }

    func testCancellationIsRecordedOnceWithoutFailure() async {
        let cancellations: [Error] = [CancellationError(), URLError(.cancelled)]
        for kind in Kind.allCases {
            for cancellation in cancellations {
                let events = DiagnosticEventRecorder()
                let fixture = fixture(kind, expired: false) { _ in throw cancellation }

                _ = await fixture.provider.refresh()

                XCTAssertEqual(fixture.refreshRequests.count, 1, kind.rawValue)
                XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, [
                    DiagnosticEvent(.credentialRefresh, result: .cancelled, providerID: kind.rawValue)
                ], kind.rawValue)
                XCTAssertFalse(events.events.contains { $0.operation == .credentialSave }, kind.rawValue)
            }
        }
    }

    func testAuthRetryCountsOnlyOneRefreshAndWritesSelectedCredentialSource() async {
        for kind in Kind.allCases {
            let events = DiagnosticEventRecorder()
            let fixture = fixture(kind, expired: false) { _ in Self.rotatedResponse }

            let snapshot = await fixture.provider.refresh()

            XCTAssertNil(snapshot.errorCategory, kind.rawValue)
            XCTAssertEqual(fixture.refreshRequests.count, 1, kind.rawValue)
            XCTAssertEqual(fixture.usageRequests.count, 2, kind.rawValue)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, [
                DiagnosticEvent(.credentialRefresh, result: .success, providerID: kind.rawValue)
            ], kind.rawValue)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialSave }, [
                DiagnosticEvent(.credentialSave, result: .success, providerID: kind.rawValue)
            ], kind.rawValue)
            XCTAssertEqual(fixture.writtenToken(), "rotated-access", kind.rawValue)
            XCTAssertEqual(fixture.keychain.values, [:], kind.rawValue)
            XCTAssertEqual(fixture.keychain.currentUserValues, [:], kind.rawValue)
            XCTAssertTrue(events.events.allSatisfy { $0.provider == kind.rawValue }, kind.rawValue)
        }
    }

    func testCursorRotationUsesSelectedKeychainWithoutWritingOtherAccountSQLite() async {
        let diagnostics = DiagnosticEventRecorder()
        let sqliteValues = [
            CursorAuthStore.accessTokenKey: Self.jwt(1),
            CursorAuthStore.refreshTokenKey: "sqlite-account-refresh",
            CursorAuthStore.membershipTypeKey: "free"
        ]
        let sqlite = RefreshDiagnosticSQLite(values: sqliteValues, failingWrite: false)
        let keychain = ServiceKeychain(values: [
            CursorAuthStore.keychainAccessTokenService: Self.jwt(1, subject: "keychain-account"),
            CursorAuthStore.keychainRefreshTokenService: "selected-keychain-refresh"
        ])
        let http = RoutingHTTPClient { request in
            if Fixture.isRefresh(request) {
                let payload = try JSONSerialization.jsonObject(with: request.body!) as? [String: String]
                XCTAssertEqual(payload?["refresh_token"], "selected-keychain-refresh")
                return Self.rotatedResponse
            }
            if Fixture.isUsage(request) {
                XCTAssertEqual(request.headers["Authorization"], "Bearer rotated-access")
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.usageBody(.cursor).utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: keychain),
            usageClient: CursorUsageClient(http: http), pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(sqlite.values, sqliteValues)
        XCTAssertEqual(keychain.values[CursorAuthStore.keychainAccessTokenService], "rotated-access")
        XCTAssertEqual(keychain.values[CursorAuthStore.keychainRefreshTokenService], "selected-keychain-refresh")
        XCTAssertEqual(diagnostics.events.filter { $0.operation == .credentialRefresh }, [
            DiagnosticEvent(.credentialRefresh, result: .success, providerID: "cursor")
        ])
        XCTAssertEqual(diagnostics.events.filter { $0.operation == .credentialSave }, [
            DiagnosticEvent(.credentialSave, result: .success, providerID: "cursor")
        ])
    }

    func testMissingRefreshTokenDoesNotInventAttempt() async {
        for kind in Kind.allCases {
            let events = DiagnosticEventRecorder()
            let fixture = fixture(kind, hasRefreshToken: false) { _ in
                XCTFail("A missing refresh token must not reach the token endpoint")
                return Self.rotatedResponse
            }

            _ = await fixture.provider.refresh()

            XCTAssertTrue(fixture.refreshRequests.isEmpty, kind.rawValue)
            XCTAssertFalse(events.events.contains { $0.operation == .credentialRefresh }, kind.rawValue)
            XCTAssertFalse(events.events.contains { $0.operation == .credentialSave }, kind.rawValue)
        }
    }

    func testPersistenceFailureDoesNotReclassifySuccessfulRotationOrDuplicateLocalLog() async throws {
        for kind in Kind.allCases {
            let events = DiagnosticEventRecorder()
            let fixture = fixture(kind, failingWrite: true) { _ in Self.rotatedResponse }
            let (snapshot, logs) = try await captureLogs { await fixture.provider.refresh() }

            XCTAssertNil(snapshot.errorCategory, kind.rawValue)
            XCTAssertEqual(snapshot.isDegraded, true, kind.rawValue)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialRefresh }, [
                DiagnosticEvent(.credentialRefresh, result: .success, providerID: kind.rawValue)
            ], kind.rawValue)
            XCTAssertEqual(events.events.filter { $0.operation == .credentialSave }, [
                DiagnosticEvent(.credentialSave, result: .degraded, category: .permission, providerID: kind.rawValue)
            ], kind.rawValue)
            let persistenceLogs = logs.split(separator: "\n").filter {
                $0.contains("credential_save") || $0.contains("failed to persist rotated")
            }
            XCTAssertEqual(persistenceLogs.count, 1, logs)
            XCTAssertTrue(persistenceLogs.first?.contains("WARN") == true, logs)
            XCTAssertFalse(logs.contains("rotated-access"), logs)
            XCTAssertFalse(logs.contains("fixture-refresh"), logs)
            XCTAssertEqual(fixture.keychain.values, [:], kind.rawValue)
            XCTAssertEqual(fixture.keychain.currentUserValues, [:], kind.rawValue)
        }
    }

    private enum Kind: String, CaseIterable { case claude, codex, cursor }

    private struct Fixture {
        let provider: any ProviderRuntime
        let http: RoutingHTTPClient
        let keychain: ServiceKeychain
        let writtenToken: () -> String?
        var refreshRequests: [HTTPRequest] { http.requests.filter { Self.isRefresh($0) } }
        var usageRequests: [HTTPRequest] { http.requests.filter { Self.isUsage($0) } }
        nonisolated static func isRefresh(_ request: HTTPRequest) -> Bool {
            request.url.path.hasSuffix("/oauth/token") || request.url == CursorUsageClient.refreshURL
        }
        nonisolated static func isUsage(_ request: HTTPRequest) -> Bool {
            request.url.path.hasSuffix("/api/oauth/usage") || request.url == CodexUsageClient.usageURL || request.url == CursorUsageClient.usageURL
        }
    }

    private func fixture(
        _ kind: Kind,
        expired: Bool = true,
        hasRefreshToken: Bool = true,
        failingWrite: Bool = false,
        refresh: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> Fixture {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = Self.jwt(expired ? 1 : 9_999_999_999)
        let refreshToken = hasRefreshToken ? "fixture-refresh" : ""
        let path = "/tmp/credential-diagnostic-\(kind.rawValue)"
        let keychain = ServiceKeychain()
        let http = RoutingHTTPClient { request in
            if Fixture.isRefresh(request) { return try await refresh(request) }
            if Fixture.isUsage(request) {
                guard request.headers["Authorization"] == "Bearer rotated-access" else {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(Self.usageBody(kind).utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let files = RefreshDiagnosticFiles(failingWrite: failingWrite)
        let provider: any ProviderRuntime
        let writtenToken: () -> String?
        switch kind {
        case .claude:
            files.values[path + "/.credentials.json"] = #"{"claudeAiOauth":{"accessToken":"\#(access)","refreshToken":"\#(refreshToken)","expiresAt":\#(expired ? 1 : 9999999999000),"scopes":["user:profile"]}}"#
            let store = ClaudeAuthStore(
                environment: FakeEnvironment([:]), files: files, keychain: keychain,
                scope: .configDir(path: path, keychainLiteral: path), now: { now }
            )
            provider = ClaudeProvider(
                provider: ClaudeProvider.makeProvider(id: "claude@fixture-account"),
                authStore: store, usageClient: ClaudeUsageClient(httpClient: http),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includePiUsage: false,
                now: { now }, pricing: { TestPricing.bundled }
            )
            writtenToken = { store.loadCredentialCandidates().first?.oauth.accessToken }
        case .codex:
            files.values[path + "/auth.json"] = #"{"tokens":{"access_token":"\#(access)","refresh_token":"\#(refreshToken)","account_id":"fixture-account"}}"#
            let store = CodexAuthStore(
                environment: FakeEnvironment([:]), files: files, keychain: keychain,
                scope: .home(path: path), now: { now }
            )
            provider = CodexProvider(
                provider: CodexProvider.makeProvider(id: "codex@fixture-account"),
                authStore: store, usageClient: CodexUsageClient(http: http),
                logUsageScanner: CodexLogFixture.scanner(home: nil), includePiUsage: false,
                now: { now }, pricing: { TestPricing.bundled }
            )
            writtenToken = { store.loadAuthCandidates().first?.auth.tokens?.accessToken }
        case .cursor:
            let sqlite = RefreshDiagnosticSQLite(values: [
                CursorAuthStore.accessTokenKey: access, CursorAuthStore.refreshTokenKey: refreshToken
            ], failingWrite: failingWrite)
            provider = CursorProvider(
                authStore: CursorAuthStore(sqlite: sqlite, keychain: keychain, now: { now }),
                usageClient: CursorUsageClient(http: http), now: { now }, pricing: { TestPricing.bundled }
            )
            writtenToken = { sqlite.values[CursorAuthStore.accessTokenKey] }
        }
        return Fixture(provider: provider, http: http, keychain: keychain, writtenToken: writtenToken)
    }

    private nonisolated static var rotatedResponse: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"access_token":"rotated-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8
        ))
    }

    private nonisolated static func usageBody(_ kind: Kind) -> String {
        switch kind {
        case .claude: #"{"five_hour":{"utilization":25}}"#
        case .codex: #"{"rate_limit":{"primary_window":{"used_percent":25}}}"#
        case .cursor: #"{"enabled":true,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#
        }
    }

    private nonisolated static func jwt(_ expiration: Int, subject: String = "fixture-account") -> String {
        let payload = Data(#"{"exp":\#(expiration),"sub":"\#(subject)"}"#.utf8).base64EncodedString()
        return "a.\(payload).c"
    }

    private func captureLogs(_ operation: () async -> ProviderSnapshot) async throws -> (ProviderSnapshot, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshDiagnosticTests.\(UUID())")
        let sink = LogFile(directory: directory, fileName: "OpenUsage.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }
        let snapshot = await operation()
        return (snapshot, try String(contentsOf: directory.appendingPathComponent("OpenUsage.log"), encoding: .utf8))
    }
}

private final class RefreshDiagnosticFiles: TextFileAccessing, @unchecked Sendable {
    var values: [String: String] = [:]
    let failingWrite: Bool
    init(failingWrite: Bool) { self.failingWrite = failingWrite }
    func exists(_ path: String) -> Bool { values[path] != nil }
    func readText(_ path: String) throws -> String { values[path] ?? "" }
    func writeText(_ path: String, _ text: String) throws {
        if failingWrite { throw CocoaError(.fileWriteNoPermission) }
        values[path] = text
    }
    func remove(_ path: String) throws { values.removeValue(forKey: path) }
}

private final class RefreshDiagnosticSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    let failingWrite: Bool
    init(values: [String: String], failingWrite: Bool) {
        self.values = values
        self.failingWrite = failingWrite
    }
    func queryValue(path: String, sql: String) throws -> String? {
        values.first { sql.contains($0.key) }?.value
    }
    func execute(path: String, sql: String) throws { XCTFail("Expected bound parameters") }
    func execute(path: String, sql: String, bindings: [String]) throws {
        if failingWrite { throw CocoaError(.fileWriteNoPermission) }
        XCTAssertEqual(bindings.count, 2)
        values[bindings[0]] = bindings[1]
    }
}
