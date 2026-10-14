import XCTest
@testable import OpenUsage

@MainActor
final class CodexSnapshotSharedCredentialTests: XCTestCase {
    func testLateRotationMirrorsTheAccountSelectedAfterTheRequestStarted() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sharedFile.path))
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        state.auth.tokens?.refreshToken = "rotated-a"

        let saved = try store.save(state)

        XCTAssertEqual(try fixture.sharedCredential(), saved.sourceText)
        XCTAssertEqual(try fixture.snapshot()?.credential, saved.sourceText)
        XCTAssertNil(try fixture.snapshot()?.codexStaleSharedCredentialFingerprints)
    }

    func testSharedWriteFailurePreservesRotationAcrossANewSwitcher() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore(files: FailingSharedWriteFiles())
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "rotated-a"

        XCTAssertThrowsError(try store.save(state)) { error in
            let failure = error as? CodexSharedCredentialSynchronizationError
            XCTAssertEqual(failure?.savedState.auth.tokens?.refreshToken, "rotated-a")
            XCTAssertNotEqual(failure?.savedState.sourceText, state.sourceText)
        }
        XCTAssertEqual(try fixture.sharedCredential(), fixture.originalA)
        XCTAssertEqual(try fixture.snapshot()?.codexStaleSharedCredentialFingerprints,
                       [CodexAuthStore.credentialFingerprint(fixture.originalA)])

        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: fixture.profileA)

        XCTAssertEqual(try fixture.snapshotToken(), "rotated-a")
        let workspaceURL = try fixture.workspace.directory(family: "codex", profileID: fixture.profileA.id)
            .appendingPathComponent("auth.json")
        let workspaceAuth = try String(contentsOf: workspaceURL, encoding: .utf8)
        XCTAssertEqual(CodexAuthStore.parseAuth(workspaceAuth)?.tokens?.refreshToken, "rotated-a")
    }

    func testNewCLICredentialOverridesTheStaleSharedMarker() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore(files: FailingSharedWriteFiles())
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "rotated-a"
        XCTAssertThrowsError(try store.save(state))
        let newCLI = fixture.originalA.replacingOccurrences(of: "refresh-a", with: "cli-refresh-a")
        try LocalTextFileAccessor().writeText(fixture.sharedFile.path, newCLI)

        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: fixture.profileA)

        XCTAssertEqual(try fixture.snapshotToken(), "cli-refresh-a")
        XCTAssertNil(try fixture.snapshot()?.codexStaleSharedCredentialFingerprints)
    }

    func testSwitchingBackClearsStaleMarkerBeforeAnotherFailedSynchronization() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        var state = try XCTUnwrap(fixture.authStore().loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "rotated-1"
        XCTAssertThrowsError(try fixture.authStore(files: FailingSharedWriteFiles()).save(state))
        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: fixture.profileA)
        state = try XCTUnwrap(fixture.authStore().loadAccountSnapshot(profileID: fixture.profileA.id))
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: fixture.profileB)
        XCTAssertNil(try fixture.snapshot()?.codexStaleSharedCredentialFingerprints)
        let selected = try fixture.sharedCredential()
        state.auth.tokens?.refreshToken = "rotated-2"

        XCTAssertThrowsError(try fixture.authStore(files: FailingSharedReadFiles()).save(state))

        XCTAssertEqual(try fixture.snapshot()?.codexStaleSharedCredentialFingerprints,
                       [CodexAuthStore.credentialFingerprint(selected)])
        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: fixture.profileA)
        XCTAssertEqual(try fixture.snapshotToken(), "rotated-2")
    }

    func testChangedSnapshotRejectsLateRotationBeforeSharedWrite() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "late-a"
        let relogin = fixture.originalA.replacingOccurrences(of: "refresh-a", with: "new-login-a")
        try fixture.vault.save(.init(credential: relogin), profile: fixture.profileA)

        XCTAssertThrowsError(try store.save(state)) { XCTAssertEqual($0 as? CodexAuthError, .credentialsChanged) }

        XCTAssertEqual(try fixture.snapshot()?.credential, relogin)
        XCTAssertEqual(try fixture.sharedCredential(), fixture.originalA)
    }

    func testDeletedSnapshotIsNotRecreatedByLateRotation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "late-a"
        try fixture.vault.delete(profile: fixture.profileA)

        XCTAssertThrowsError(try store.save(state)) { XCTAssertEqual($0 as? CodexAuthError, .credentialsChanged) }

        XCTAssertNil(try fixture.snapshot())
        XCTAssertEqual(try fixture.sharedCredential(), fixture.originalA)
    }

    func testChangedSharedDocumentIsNotOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "late-a"
        let changed = fixture.originalA.replacingOccurrences(of: "\"last_refresh\"", with: "\"cli_metadata\":true,\"last_refresh\"")
        try LocalTextFileAccessor().writeText(fixture.sharedFile.path, changed)

        _ = try store.save(state)

        XCTAssertEqual(try fixture.sharedCredential(), changed)
        XCTAssertEqual(try fixture.snapshotToken(), "late-a")
    }

    func testDifferentSelectedAccountIsNotOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: nil)
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "late-a"
        let selected = try fixture.sharedCredential()

        _ = try store.save(state)

        XCTAssertEqual(try fixture.sharedCredential(), selected)
        XCTAssertEqual(try fixture.snapshotToken(), "late-a")
    }

    func testMissingSharedFileIsNotRecreated() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "late-a"

        _ = try store.save(state)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sharedFile.path))
        XCTAssertEqual(try fixture.snapshotToken(), "late-a")
    }

    func testSnapshotWriteFailureDoesNotChangeSharedCredentials() throws {
        let keychain = SnapshotWriteFailureKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "rotated-a"
        keychain.failAtWrite = keychain.writeCount + 1

        XCTAssertThrowsError(try store.save(state))

        XCTAssertEqual(try fixture.sharedCredential(), fixture.originalA)
        XCTAssertEqual(try fixture.snapshot()?.credential, fixture.originalA)
    }

    func testMarkerCleanupFailureKeepsBothRotatedCredentials() throws {
        let keychain = SnapshotWriteFailureKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let store = fixture.authStore()
        var state = try XCTUnwrap(store.loadAccountSnapshot(profileID: fixture.profileA.id))
        state.auth.tokens?.refreshToken = "rotated-a"
        keychain.failAtWrite = keychain.writeCount + 2

        XCTAssertThrowsError(try store.save(state)) { error in
            XCTAssertEqual((error as? CodexSharedCredentialSynchronizationError)?.savedState.auth.tokens?.refreshToken,
                           "rotated-a")
        }

        XCTAssertEqual(try fixture.sharedCredential(), try fixture.snapshot()?.credential)
        XCTAssertEqual(try fixture.snapshotToken(), "rotated-a")
        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: fixture.profileA)
        XCTAssertEqual(try fixture.snapshotToken(), "rotated-a")
        XCTAssertNil(try fixture.snapshot()?.codexStaleSharedCredentialFingerprints)
    }

    func testUsage401RetryContinuesFromTheSnapshotSavedDuringSharedFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.switcher.switchAuthentication(to: fixture.profileA, from: nil)
        let originalSink = AppLog.sink
        AppLog.sink = LogFile(directory: fixture.home.appendingPathComponent("logs"), fileName: "fixture.log")
        defer { AppLog.sink = originalSink }
        let http = RetryAfterSharedFailureHTTP()
        let provider = CodexProvider(
            authStore: fixture.authStore(files: FailingSharedWriteFiles()),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(
                environment: FakeEnvironment(), incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
                cacheIdentityOverride: UUID().uuidString, rootsOverride: []
            ),
            includePiUsage: false, pricing: { .empty }
        )

        let result = await provider.refresh()

        XCTAssertEqual(result.isDegraded, true)
        XCTAssertEqual(result.warning, "Codex sign-in was saved, but shared sign-in synchronization did not finish.")
        XCTAssertEqual(try fixture.snapshotToken(), "rotated-refresh-2")
        let rotations = await http.refreshTokens
        XCTAssertEqual(rotations, ["refresh-a", "rotated-refresh-1"])
        let nextResult = await provider.refresh()
        XCTAssertNil(nextResult.warning)
        try fixture.switcher.switchAuthentication(to: fixture.profileB, from: fixture.profileA)
        XCTAssertEqual(try fixture.snapshotToken(), "rotated-refresh-2")
    }

    private struct Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("CodexSnapshotSync.\(UUID().uuidString)")
        let keychain: any KeychainAccessing
        let profileA = AccountProfile(id: "a", family: "codex", label: "A", identityKey: "account-a", createdAt: .distantPast)
        let profileB = AccountProfile(id: "b", family: "codex", label: "B", identityKey: "account-b", createdAt: .distantPast)
        let originalA = #"{"tokens":{"access_token":"access-a","refresh_token":"refresh-a","account_id":"account-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        var sharedFile: URL { home.appendingPathComponent(".codex/auth.json") }
        var workspace: AccountSignInWorkspace { AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("sign-in")) }
        var vault: AccountCredentialVault { AccountCredentialVault(keychain: keychain) }
        var switcher: AccountCredentialSwitcher {
            AccountCredentialSwitcher(keychain: keychain, environment: FakeEnvironment(), homeDirectory: home, workspace: workspace)
        }

        init(keychain: any KeychainAccessing = ServiceKeychain()) throws {
            self.keychain = keychain
            try vault.save(.init(credential: originalA), profile: profileA)
            try vault.save(.init(credential: originalA.replacingOccurrences(of: "-a", with: "-b")), profile: profileB)
        }

        func authStore(files: any TextFileAccessing = LocalTextFileAccessor()) -> CodexAuthStore {
            CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: keychain,
                           scope: .accountSnapshot(profileID: profileA.id),
                           managedSharedAuthHome: sharedFile.deletingLastPathComponent().path)
        }

        func snapshot() throws -> AccountCredentialVault.Entry? { try vault.load(profile: profileA) }
        func snapshotToken() throws -> String? { try snapshot().flatMap { CodexAuthStore.parseAuth($0.credential)?.tokens?.refreshToken } }
        func sharedCredential() throws -> String { try String(contentsOf: sharedFile, encoding: .utf8) }
        func cleanUp() { try? FileManager.default.removeItem(at: home) }
    }
}

private struct FailingSharedWriteFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { LocalTextFileAccessor().exists(path) }
    func readText(_ path: String) throws -> String { try LocalTextFileAccessor().readText(path) }
    func readTextIfPresent(_ path: String) throws -> String? { try LocalTextFileAccessor().readTextIfPresent(path) }
    func writeText(_ path: String, _ text: String) throws { throw CocoaError(.fileWriteNoPermission) }
    func remove(_ path: String) throws { try LocalTextFileAccessor().remove(path) }
}

private struct FailingSharedReadFiles: TextFileAccessing {
    func exists(_ path: String) -> Bool { true }
    func readText(_ path: String) throws -> String { throw CocoaError(.fileReadNoPermission) }
    func writeText(_ path: String, _ text: String) throws { try LocalTextFileAccessor().writeText(path, text) }
    func remove(_ path: String) throws { try LocalTextFileAccessor().remove(path) }
}

private actor RetryAfterSharedFailureHTTP: HTTPClient {
    private(set) var refreshTokens: [String] = []
    private var usageRequests = 0

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url == CodexUsageClient.refreshURL {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            let token = body.components(separatedBy: "&refresh_token=").last?.removingPercentEncoding
            refreshTokens.append(token ?? "missing")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                "{\"access_token\":\"rotated-access-\(refreshTokens.count)\",\"refresh_token\":\"rotated-refresh-\(refreshTokens.count)\"}".utf8
            ))
        }
        usageRequests += 1
        if usageRequests == 1 { return HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#.utf8
        ))
    }
}

private final class SnapshotWriteFailureKeychain: KeychainAccessing, @unchecked Sendable {
    private let base = ServiceKeychain()
    var failAtWrite: Int?
    private(set) var writeCount = 0

    func readGenericPassword(service: String) throws -> String? { try base.readGenericPassword(service: service) }
    func writeGenericPassword(service: String, value: String) throws { try base.writeGenericPassword(service: service, value: value) }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try base.readGenericPasswordForCurrentUser(service: service)
    }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        writeCount += 1
        if writeCount == failAtWrite { throw CocoaError(.fileWriteNoPermission) }
        try base.writeGenericPasswordForCurrentUser(service: service, value: value)
    }
    func deleteGenericPassword(service: String) throws { try base.deleteGenericPassword(service: service) }
}
