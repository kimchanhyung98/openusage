import XCTest
@testable import OpenUsage

@MainActor
final class CodexCredentialPreservationTests: XCTestCase {
    private nonisolated static let path = "/credential-preservation/auth.json"
    private nonisolated static let original = #"{"auth_mode":"chatgpt","root_sentinel":{"keep":true},"tokens":{"access_token":"old","refresh_token":"refresh-A","account_id":"A","token_sentinel":[1,2]},"last_refresh":"2020-01-01T00:00:00Z"}"#
    private nonisolated static let replacement = #"{"auth_mode":"chatgpt","tokens":{"access_token":"new-login","refresh_token":"refresh-B","account_id":"B"}}"#

    func testDelayedRefreshDoesNotOverwriteANewFileLogin() async throws {
        let files = FakeFiles([Self.path: Self.original])
        let http = PreservationHTTP {
            files.files[Self.path] = Self.replacement
        }
        let provider = makeProvider(
            store: CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                                  scope: .home(path: "/credential-preservation")), http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(files.files[Self.path], Self.replacement)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.authenticationIssue)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testDelayedRefreshDoesNotOverwriteANewKeychainLogin() async {
        let keychain = FakeKeychain(Self.original)
        let http = PreservationHTTP { keychain.value = Self.replacement }
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(keychain.value, Self.replacement)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testDelayedRefreshDoesNotOverwriteANewSavedSnapshot() async throws {
        let service = AccountCredentialVault.service(family: "codex", profileID: "saved")
        let originalEntry = try entry(Self.original)
        let replacementEntry = try entry(Self.replacement)
        let keychain = ServiceKeychain(currentUserValues: [service: originalEntry])
        let http = PreservationHTTP { keychain.currentUserValues[service] = replacementEntry }
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: "saved")
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(keychain.currentUserValues[service], replacementEntry)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testSourceRemovalOrUnknownFieldChangeDuringRefreshIsPreserved() async {
        for replacement in [nil, Self.original.replacingOccurrences(of: "true", with: "false"), "invalid-json"] as [String?] {
            let files = FakeFiles([Self.path: Self.original])
            let http = PreservationHTTP { files.files[Self.path] = replacement }
            let provider = makeProvider(store: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                scope: .home(path: "/credential-preservation")
            ), http: http)

            let snapshot = await provider.refresh()

            XCTAssertEqual(files.files[Self.path], replacement)
            XCTAssertNotNil(snapshot.errorCategory)
            XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        }
    }

    func testUnauthorizedRetryCannotOverwriteANewLogin() async {
        let fresh = Self.original.replacingOccurrences(of: "2020-01-01T00:00:00Z", with: OpenUsageISO8601.string(from: Date()))
        let files = FakeFiles([Self.path: fresh])
        let http = PreservationHTTP(rejectFirstUsage: true) { files.files[Self.path] = Self.replacement }
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: "/credential-preservation")
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(files.files[Self.path], Self.replacement)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL, CodexUsageClient.refreshURL])
    }

    func testSavePreservesUnknownRootAndTokenFields() throws {
        for input in [Self.original, Self.original.utf8.map { String(format: "%02x", $0) }.joined()] {
            let files = FakeFiles([Self.path: input])
            let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
            var state = try XCTUnwrap(store.loadAuth(at: Self.path))
            state.auth.tokens?.accessToken = "rotated"
            state.auth.tokens?.refreshToken = "rotated-refresh"
            state.auth.lastRefresh = "2026-10-05T00:00:00Z"

            try store.save(state)

            let saved = try XCTUnwrap(files.files[Self.path])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
            XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
            XCTAssertEqual(object["root_sentinel"] as? [String: Bool], ["keep": true])
            let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["token_sentinel"] as? [Int], [1, 2])
            XCTAssertEqual(tokens["access_token"] as? String, "rotated")
            XCTAssertEqual(tokens["refresh_token"] as? String, "rotated-refresh")
        }
    }

    func testKeychainAndSnapshotSavePreserveCredentialEnvelope() throws {
        let service = AccountCredentialVault.service(family: "codex", profileID: "saved")
        let keychain = ServiceKeychain(values: [CodexAuthStore.keychainService: Self.original],
                                      currentUserValues: [service: try entry(Self.original)])
        let standard = CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain)
        let snapshot = CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                      scope: .accountSnapshot(profileID: "saved"))
        for (store, loaded) in [(standard, standard.loadKeychainAuth()),
                               (snapshot, try snapshot.loadAccountSnapshot(profileID: "saved"))] {
            var state = try XCTUnwrap(loaded)
            state.auth.tokens?.accessToken = "rotated"
            try store.save(state)
        }
        let savedSnapshot = try XCTUnwrap(AccountCredentialVault(keychain: keychain).load(family: "codex", profileID: "saved"))
        XCTAssertEqual(savedSnapshot.claudeOAuthAccount, "wrapper-sentinel")
        for text in [try XCTUnwrap(keychain.values[CodexAuthStore.keychainService]), savedSnapshot.credential] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
            XCTAssertEqual(object["root_sentinel"] as? [String: Bool], ["keep": true])
            let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["token_sentinel"] as? [Int], [1, 2])
            XCTAssertEqual(tokens["access_token"] as? String, "rotated")
        }
    }

    func testSaveWithoutALoadedSourceRevisionCannotWrite() throws {
        let files = FakeFiles([Self.path: Self.replacement])
        let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
        let state = CodexAuthState(auth: try XCTUnwrap(CodexAuthStore.parseAuth(Self.original)),
                                  source: .file(path: Self.path))

        XCTAssertThrowsError(try store.save(state))

        XCTAssertEqual(files.files[Self.path], Self.replacement)
    }

    func testUnchangedNullFieldsRemainInTheDocument() throws {
        let raw = #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"old","refresh_token":null,"id_token":null,"account_id":"A","extra":null},"future":{"list":[true,null,{"nested":"keep"}]}}"#
        let files = FakeFiles([Self.path: raw])
        let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
        var state = try XCTUnwrap(store.loadAuth(at: Self.path))
        state.auth.tokens?.accessToken = "rotated"

        try store.save(state)

        let saved = try XCTUnwrap(files.files[Self.path])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertTrue(object["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(object["future"] as? NSDictionary, original["future"] as? NSDictionary)
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertTrue(tokens["refresh_token"] is NSNull)
        XCTAssertTrue(tokens["id_token"] is NSNull)
        XCTAssertTrue(tokens["extra"] is NSNull)
        XCTAssertEqual(tokens["account_id"] as? String, "A")
    }

    func testUnchangedRefreshPersistsTokensAndRetainsEnvelope() async throws {
        let files = FakeFiles([Self.path: Self.original])
        let http = PreservationHTTP {}
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: "/credential-preservation")
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        let text = try XCTUnwrap(files.files[Self.path])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual(object["root_sentinel"] as? [String: Bool], ["keep": true])
        XCTAssertEqual(CodexAuthStore.parseAuth(text)?.tokens?.accessToken, "rotated-A")
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL, CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL])
    }

    private func entry(_ credential: String) throws -> String {
        String(decoding: try JSONEncoder().encode(AccountCredentialVault.Entry(
            credential: credential, claudeOAuthAccount: "wrapper-sentinel"
        )), as: UTF8.self)
    }

    private func makeProvider(store: CodexAuthStore, http: PreservationHTTP) -> CodexProvider {
        CodexProvider(
            authStore: store, usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(environment: FakeEnvironment(),
                cacheIdentityOverride: "credential-preservation", rootsOverride: []), includePiUsage: false,
            pricing: { .empty }
        )
    }
}

private final class PreservationHTTP: HTTPClient, @unchecked Sendable {
    let onRefresh: @Sendable () -> Void
    let rejectFirstUsage: Bool
    var requests: [HTTPRequest] = []
    init(rejectFirstUsage: Bool = false, onRefresh: @escaping @Sendable () -> Void) {
        self.rejectFirstUsage = rejectFirstUsage
        self.onRefresh = onRefresh
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if rejectFirstUsage, requests.count == 1 {
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        if request.method == "POST" {
            onRefresh()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"rotated-A","refresh_token":"rotated-refresh-A"}"#.utf8
            ))
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#.utf8
        ))
    }
}
