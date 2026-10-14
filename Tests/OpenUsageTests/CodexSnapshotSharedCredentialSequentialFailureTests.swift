import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexSnapshotSharedCredentialSequentialFailureTests: XCTestCase {
    func test401RetryAfterMarkerCleanupFailurePreservesNewestSnapshotOnSwitchAway() async throws {
        try await assertSequentialFailure(first: .markerCleanup, completion: .switchAway)
    }

    func test401RetryAfterSharedWriteFailurePreservesNewestSnapshotOnSwitchAway() async throws {
        try await assertSequentialFailure(first: .sharedWrite, completion: .switchAway)
    }

    func testNewCLISignInAfterSequentialFailuresRemainsAuthoritative() async throws {
        for first in FirstFailure.allCases {
            try await assertSequentialFailure(first: first, completion: .newCLISignIn)
        }
    }

    func testRecoveredSharedReadNarrowsCandidatesAndSuccessfulSyncClearsThem() async throws {
        for first in FirstFailure.allCases {
            try await assertSequentialFailure(first: first, completion: .recoverSynchronization)
        }
    }

    private enum FirstFailure: CaseIterable { case markerCleanup, sharedWrite }
    private enum Completion { case switchAway, newCLISignIn, recoverSynchronization }

    private func assertSequentialFailure(first: FirstFailure, completion: Completion) async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSequentialFailure.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let previousLog = AppLog.sink
        AppLog.sink = LogFile(directory: home.appendingPathComponent("logs"), fileName: "fixture.log")
        defer { AppLog.sink = previousLog }

        let keychain = SequentialFailureKeychain()
        let vault = AccountCredentialVault(keychain: keychain)
        let profileA = AccountProfile(id: "a", family: "codex", label: "A", identityKey: "account-a", createdAt: .distantPast)
        let profileB = AccountProfile(id: "b", family: "codex", label: "B", identityKey: "account-b", createdAt: .distantPast)
        let original = #"{"tokens":{"access_token":"access-a","refresh_token":"refresh-a","account_id":"account-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        try vault.save(.init(credential: original), profile: profileA)
        try vault.save(.init(credential: original.replacingOccurrences(of: "-a", with: "-b")), profile: profileB)
        let workspace = AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("sign-in"))
        let switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: SequentialFailureEnvironment(), homeDirectory: home, workspace: workspace
        )
        try switcher.switchAuthentication(to: profileA, from: nil)
        let sharedFile = home.appendingPathComponent(".codex/auth.json")
        let files = SequentialFailureFiles(sharedPath: sharedFile.path)
        let http = SequentialFailureHTTP(files: files)
        switch first {
        case .markerCleanup: keychain.failSecondUpcomingWrite()
        case .sharedWrite: files.failNextSharedWrite()
        }
        let authStore = CodexAuthStore(
            environment: SequentialFailureEnvironment(), files: files, keychain: keychain,
            scope: .accountSnapshot(profileID: profileA.id),
            managedSharedAuthHome: sharedFile.deletingLastPathComponent().path
        )
        let provider = CodexProvider(
            authStore: authStore,
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(
                environment: SequentialFailureEnvironment(),
                incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
                cacheIdentityOverride: UUID().uuidString, rootsOverride: []
            ),
            includePiUsage: false, pricing: { .empty }
        )

        let result = await provider.refresh()

        XCTAssertEqual(result.isDegraded, true)
        let refreshTokens = await http.refreshTokens
        XCTAssertEqual(refreshTokens, ["refresh-a", "rotated-refresh-1"])
        XCTAssertEqual(keychain.injectedFailures, first == .markerCleanup ? 1 : 0)
        XCTAssertEqual(files.injectedReadFailures, 1)
        XCTAssertEqual(files.injectedWriteFailures, first == .sharedWrite ? 1 : 0)
        let beforeSwitch = try XCTUnwrap(vault.load(profile: profileA))
        XCTAssertEqual(CodexAuthStore.parseAuth(beforeSwitch.credential)?.tokens?.refreshToken, "rotated-refresh-2")
        let sharedBeforeSwitch = try String(contentsOf: sharedFile, encoding: .utf8)
        XCTAssertEqual(
            CodexAuthStore.parseAuth(sharedBeforeSwitch)?.tokens?.refreshToken,
            first == .markerCleanup ? "rotated-refresh-1" : "refresh-a"
        )

        let expectedToken: String
        switch completion {
        case .switchAway:
            expectedToken = "rotated-refresh-2"
        case .newCLISignIn:
            expectedToken = "cli-refresh-a"
            try LocalTextFileAccessor().writeText(
                sharedFile.path, original.replacingOccurrences(of: "refresh-a", with: expectedToken)
            )
        case .recoverSynchronization:
            var third = try XCTUnwrap(authStore.loadAccountSnapshot(profileID: profileA.id))
            third.auth.tokens?.refreshToken = "rotated-refresh-3"
            files.failNextSharedWrite()
            XCTAssertThrowsError(try authStore.save(third)) { error in
                let failure = error as? CodexSharedCredentialSynchronizationError
                XCTAssertEqual(failure?.savedState.auth.tokens?.refreshToken, "rotated-refresh-3")
            }
            let narrowed = try XCTUnwrap(vault.load(profile: profileA))
            XCTAssertEqual(
                narrowed.codexStaleSharedCredentialFingerprints,
                [CodexAuthStore.credentialFingerprint(sharedBeforeSwitch)]
            )
            XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), sharedBeforeSwitch)
            var fourth = try XCTUnwrap(authStore.loadAccountSnapshot(profileID: profileA.id))
            expectedToken = "rotated-refresh-4"
            fourth.auth.tokens?.refreshToken = expectedToken
            let saved = try authStore.save(fourth)
            XCTAssertEqual(try String(contentsOf: sharedFile, encoding: .utf8), saved.sourceText)
            XCTAssertNil(try vault.load(profile: profileA)?.codexStaleSharedCredentialFingerprints)
        }

        try switcher.switchAuthentication(to: profileB, from: profileA)

        let afterSwitch = try XCTUnwrap(vault.load(profile: profileA))
        XCTAssertEqual(
            CodexAuthStore.parseAuth(afterSwitch.credential)?.tokens?.refreshToken,
            expectedToken,
            "Switch-away must retain the newest known authentication after sequential synchronization failures"
        )
        if completion != .switchAway { XCTAssertNil(afterSwitch.codexStaleSharedCredentialFingerprints) }
        let workspaceFile = try workspace.directory(family: "codex", profileID: profileA.id).appendingPathComponent("auth.json")
        let workspaceText = try String(contentsOf: workspaceFile, encoding: .utf8)
        XCTAssertEqual(CodexAuthStore.parseAuth(workspaceText)?.tokens?.refreshToken, expectedToken)
    }
}

private struct SequentialFailureEnvironment: EnvironmentReading {
    func value(for name: String) -> String? { nil }
}

private final class SequentialFailureFiles: TextFileAccessing, @unchecked Sendable {
    private let sharedPath: String
    private let lock = NSLock()
    private var failRead = false
    private var failWrite = false
    private var readFailureCount = 0
    private var writeFailureCount = 0
    var injectedReadFailures: Int { lock.withLock { readFailureCount } }
    var injectedWriteFailures: Int { lock.withLock { writeFailureCount } }

    init(sharedPath: String) { self.sharedPath = sharedPath }

    func failNextSharedRead() { lock.withLock { failRead = true } }
    func failNextSharedWrite() { lock.withLock { failWrite = true } }

    func exists(_ path: String) -> Bool {
        precondition(path == sharedPath)
        return LocalTextFileAccessor().exists(path)
    }

    func readText(_ path: String) throws -> String {
        precondition(path == sharedPath)
        return try LocalTextFileAccessor().readText(path)
    }

    func readTextIfPresent(_ path: String) throws -> String? {
        precondition(path == sharedPath)
        let shouldFail = lock.withLock {
            guard failRead else { return false }
            failRead = false
            readFailureCount += 1
            return true
        }
        if shouldFail { throw CocoaError(.fileReadNoPermission) }
        return try LocalTextFileAccessor().readTextIfPresent(path)
    }

    func writeText(_ path: String, _ text: String) throws {
        precondition(path == sharedPath)
        let shouldFail = lock.withLock {
            guard failWrite else { return false }
            failWrite = false
            writeFailureCount += 1
            return true
        }
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try LocalTextFileAccessor().writeText(path, text)
    }

    func remove(_ path: String) throws {
        precondition(path == sharedPath)
        try LocalTextFileAccessor().remove(path)
    }
}

private actor SequentialFailureHTTP: HTTPClient {
    let files: SequentialFailureFiles
    private(set) var refreshTokens: [String] = []
    private var usageRequests = 0

    init(files: SequentialFailureFiles) { self.files = files }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url == CodexUsageClient.refreshURL {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            let token = body.components(separatedBy: "&refresh_token=").last?.removingPercentEncoding
            refreshTokens.append(token ?? "missing")
            if refreshTokens.count == 2 { files.failNextSharedRead() }
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

private final class SequentialFailureKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var writeCount = 0
    private var failAtWrite: Int?
    private var failureCount = 0
    var injectedFailures: Int { lock.withLock { failureCount } }

    func failSecondUpcomingWrite() { lock.withLock { failAtWrite = writeCount + 2 } }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        lock.withLock { values[(forCurrentUser ? "user:" : "service:") + service] }
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.withLock { values["service:" + service] }
    }

    func writeGenericPassword(service: String, value: String) throws {
        lock.withLock { values["service:" + service] = value }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        lock.withLock { values["user:" + service] }
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try lock.withLock {
            writeCount += 1
            if writeCount == failAtWrite {
                failureCount += 1
                throw CocoaError(.fileWriteNoPermission)
            }
            values["user:" + service] = value
        }
    }

    func deleteGenericPassword(service: String) throws {
        lock.withLock {
            values["service:" + service] = nil
            values["user:" + service] = nil
        }
    }
}
