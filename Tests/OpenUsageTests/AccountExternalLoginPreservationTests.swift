import XCTest
@testable import OpenUsage

@MainActor
final class AccountExternalLoginPreservationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var keychain: ServiceKeychain!
    private var workspace: AccountSignInWorkspace!
    private var switcher: AccountCredentialSwitcher!
    private var importer: AccountCredentialImporter!
    private var store: AccountProfilesStore!
    private var profile: AccountProfile!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountExternalLoginPreservationTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AccountExternalLoginPreservationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [root, defaults] in
            defaults?.removePersistentDomain(forName: suite)
            if let root { try? FileManager.default.removeItem(at: root) }
        }
        keychain = ServiceKeychain()
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        store = AccountProfilesStore(defaults: defaults)
        profile = try store.add(
            family: "claude", label: "Work", identityKey: "acct-b|org-b", id: "profile-b"
        )
        let saved = entry(token: "saved-b", account: "b")
        try switcher.saveSnapshot(saved, for: profile)
        try switcher.writeWorkspaceAuthentication(saved, for: profile)
    }

    func testNewerDivergentBaseLoginPreservesSavedAccountAndSharedAuthentication() throws {
        let scoped = entry(token: "scoped-b", account: "b")
        try seedShared(
            scoped: scoped, scopedTime: 100,
            base: entry(token: "newer-base-c", account: "c"), baseTime: 200
        )

        XCTAssertEqual(try switcher.readSharedClaudeAuthenticationForReadiness(), scoped)
        try assertConflictPreservesAuthentication()
    }

    func testNewerRootWithOlderBaseIsPreservedAfterStartup() async throws {
        try seedShared(
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 200,
            base: entry(token: "older-base-c", account: "c"), baseTime: 100
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 300)], ofItemAtPath: rootState.path
        )
        let before = try captureArtifacts()
        let result: Result<AccountCredentialImporter.ExternalReauthenticationResult, any Swift.Error>

        do {
            result = .success(try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store))
        } catch {
            result = .failure(error)
        }

        try assertPreserved(before)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .conflictingClaudeAuthentication)
        }
    }

    func testNewerBaseWithOlderRootIsPreserved() throws {
        try seedShared(
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 200,
            base: entry(token: "newer-base-c", account: "c"), baseTime: 300
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: rootState.path
        )

        try assertConflictPreservesAuthentication()
    }

    func testEqualWriteGenerationsPreserveConflictingAuthentication() throws {
        try seedShared(
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 200,
            base: entry(token: "same-time-base-c", account: "c"), baseTime: 200
        )

        try assertConflictPreservesAuthentication()
    }

    func testMissingCredentialWriteGenerationPreservesConflictingAuthentication() throws {
        for serviceWithoutDate in [scopedService, baseService] {
            try seedShared(
                scoped: entry(token: "scoped-b", account: "b"), scopedTime: 200,
                base: entry(token: "older-base-c", account: "c"), baseTime: 100
            )
            keychain.currentUserModificationDates[serviceWithoutDate] = nil

            try assertConflictPreservesAuthentication()
        }
    }

    func testUnchangedSnapshotDoesNotBypassConflictingLoginPreservation() throws {
        let saved = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        try seedShared(
            scoped: saved, scopedTime: 100,
            base: entry(token: "newer-base-c", account: "c"), baseTime: 200
        )

        XCTAssertEqual(try switcher.readSharedClaudeAuthenticationForReadiness(), saved)
        try assertConflictPreservesAuthentication()
    }

    func testExternalLoginBetweenValidationAndNormalizationDecisionIsPreserved() throws {
        let saved = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        try seedShared(scoped: saved, scopedTime: 100, base: saved, baseTime: 100)
        let external = entry(token: "external-c", account: "c")
        let externalAccount = try XCTUnwrap(external.claudeOAuthAccount)
        let externalRoot = Data(#"{"keep":"root","oauthAccount":\#(externalAccount)}"#.utf8)
        let externalDate = Date(timeIntervalSince1970: 200)
        var expected = try captureArtifacts()
        expected.currentUserValues[baseService] = external.credential
        expected.currentUserModificationDates[baseService] = externalDate
        expected.files[rootState.path] = externalRoot
        let observingKeychain = SecondScopedReadKeychain(
            storage: keychain, scopedService: scopedService
        ) { [storage = keychain!, baseService, rootState] in
            storage.currentUserValues[baseService] = external.credential
            storage.currentUserModificationDates[baseService] = externalDate
            try externalRoot.write(to: rootState)
            try FileManager.default.setAttributes([.modificationDate: externalDate], ofItemAtPath: rootState.path)
        }
        let observingImporter = AccountCredentialImporter(
            keychain: observingKeychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )

        let result = Result { try observingImporter.reconcileSelectedClaudeSharedAuthentication(in: store) }

        XCTAssertTrue(observingKeychain.didMutate)
        try assertPreserved(expected)
        switch result {
        case .success(let reconciliation):
            XCTAssertEqual(reconciliation, .unchanged)
        case .failure(let error):
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .conflictingClaudeAuthentication)
        }
    }

    func testScopedTokenRotationDoesNotEraseBaseLoginNewerThanLocalState() throws {
        try seedShared(
            scoped: entry(token: "rotated-b", account: "b"), scopedTime: 300,
            base: entry(token: "middle-base-c", account: "c"), baseTime: 200
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: localState.path
        )

        try assertConflictPreservesAuthentication()
    }

    func testSameIdentityScopedTokenRotationDoesNotRequireNewStateGeneration() throws {
        let rotated = entry(token: "rotated-b", account: "b")
        let base = entry(token: "base-b", account: "b")
        try seedShared(scoped: rotated, scopedTime: 300, base: base, baseTime: 100)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: localState.path
        )
        let before = try captureArtifacts()

        let result = try importer.reconcileSelectedClaudeSharedAuthentication(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), rotated)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "claude", profileID: profile.id)?.entry, rotated)
        XCTAssertEqual(keychain.currentUserValues[scopedService], rotated.credential)
        XCTAssertEqual(keychain.currentUserValues[baseService], base.credential)
        for url in [rootState, localState, sharedHome.appendingPathComponent(".credentials.json")] {
            XCTAssertEqual(try Data(contentsOf: url), before.files[url.path])
        }
        XCTAssertEqual(store.profile(id: profile.id), profile)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
        XCTAssertNil(try store.pendingIdentityReplacement())
    }

    func testOlderDivergentBaseLoginIsNormalizedToTheScopedAccount() throws {
        let scoped = entry(token: "newer-scoped-b", account: "b")
        try seedShared(
            scoped: scoped, scopedTime: 200,
            base: entry(token: "older-base-c", account: "c"), baseTime: 100
        )

        try assertReconcilesScopedAuthentication(scoped)
    }

    func testOlderLegacyBaseUsesItsOwnModificationDateForNormalization() throws {
        let scoped = entry(token: "newer-scoped-b", account: "b")
        let legacyBase = entry(token: "older-legacy-c", account: "c")
        try seedShared(scoped: scoped, scopedTime: 200, base: legacyBase, baseTime: 100)
        keychain.currentUserValues[baseService] = nil
        keychain.currentUserModificationDates[baseService] = Date(timeIntervalSince1970: 300)
        keychain.values[baseService] = legacyBase.credential
        keychain.modificationDates[baseService] = Date(timeIntervalSince1970: 100)

        try assertReconcilesScopedAuthentication(scoped)
    }

    private func assertConflictPreservesAuthentication(file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try captureArtifacts()
        let result = Result { try importer.reconcileSelectedClaudeSharedAuthentication(in: store) }

        try assertPreserved(before, file: file, line: line)
        XCTAssertThrowsError(try result.get(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? AccountCredentialSwitcher.Error, .conflictingClaudeAuthentication, file: file, line: line
            )
        }
    }

    private func assertReconcilesScopedAuthentication(_ scoped: AccountCredentialVault.Entry) throws {
        let result = try importer.reconcileSelectedClaudeSharedAuthentication(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        XCTAssertEqual(store.profile(id: profile.id), profile)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
        XCTAssertEqual(store.authenticationRevision, 1)
        XCTAssertNil(try store.pendingIdentityReplacement())
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), scoped)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "claude", profileID: profile.id)?.entry, scoped)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "claude"), scoped)
        XCTAssertEqual(keychain.currentUserValues[baseService], scoped.credential)
        XCTAssertEqual(keychain.currentUserValues[scopedService], scoped.credential)
        XCTAssertEqual(
            try String(contentsOf: sharedHome.appendingPathComponent(".credentials.json"), encoding: .utf8),
            scoped.credential
        )
        for stateURL in [rootState, localState] {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
            XCTAssertEqual(state["keep"] as? String, stateURL == rootState ? "root" : "local")
            let account = try XCTUnwrap(state["oauthAccount"] as? [String: Any])
            XCTAssertEqual(account["accountUuid"] as? String, "acct-b")
            XCTAssertEqual(account["organizationUuid"] as? String, "org-b")
        }
    }

    private var sharedHome: URL { root.appendingPathComponent(".claude") }
    private var rootState: URL { root.appendingPathComponent(".claude.json") }
    private var localState: URL { sharedHome.appendingPathComponent(".claude.json") }
    private var baseService: String { ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment()) }
    private var scopedService: String {
        ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome.path, environment: FakeEnvironment()
        )
    }

    private func entry(token: String, account: String) -> AccountCredentialVault.Entry {
        AccountCredentialVault.Entry(
            credential: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(account)"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
        )
    }

    private func seedShared(
        scoped: AccountCredentialVault.Entry, scopedTime: TimeInterval,
        base: AccountCredentialVault.Entry, baseTime: TimeInterval
    ) throws {
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        keychain.currentUserValues[scopedService] = scoped.credential
        keychain.currentUserValues[baseService] = base.credential
        keychain.currentUserModificationDates[scopedService] = Date(timeIntervalSince1970: scopedTime)
        keychain.currentUserModificationDates[baseService] = Date(timeIntervalSince1970: baseTime)
        try writeState(scoped, at: localState, time: scopedTime, marker: "local")
        try writeState(base, at: rootState, time: baseTime, marker: "root")
        let credentialFile = sharedHome.appendingPathComponent(".credentials.json")
        try Data(scoped.credential.utf8).write(to: credentialFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: scopedTime)], ofItemAtPath: credentialFile.path
        )
    }

    private func writeState(
        _ credential: AccountCredentialVault.Entry, at url: URL, time: TimeInterval, marker: String
    ) throws {
        let account = try XCTUnwrap(credential.claudeOAuthAccount)
        try Data(#"{"keep":"\#(marker)","oauthAccount":\#(account)}"#.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path
        )
    }

    private struct Artifacts {
        var values: [String: String]
        var currentUserValues: [String: String]
        var modificationDates: [String: Date]
        var currentUserModificationDates: [String: Date]
        var files: [String: Data]
        var registry: Data?
    }

    private func captureArtifacts() throws -> Artifacts {
        let workspaceHome = try workspace.directory(family: "claude", profileID: profile.id)
        let urls = [
            rootState, localState, sharedHome.appendingPathComponent(".credentials.json"),
            workspaceHome.appendingPathComponent(".claude.json"),
            workspaceHome.appendingPathComponent(".credentials.json")
        ]
        var files: [String: Data] = [:]
        for url in urls {
            files[url.path] = try Data(contentsOf: url)
        }
        return Artifacts(
            values: keychain.values, currentUserValues: keychain.currentUserValues,
            modificationDates: keychain.modificationDates,
            currentUserModificationDates: keychain.currentUserModificationDates,
            files: files, registry: defaults.data(forKey: AccountProfilesStore.storageKey)
        )
    }

    private func assertPreserved(_ before: Artifacts, file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try captureArtifacts()
        XCTAssertEqual(after.values, before.values, file: file, line: line)
        XCTAssertEqual(after.currentUserValues, before.currentUserValues, file: file, line: line)
        XCTAssertEqual(after.modificationDates, before.modificationDates, file: file, line: line)
        XCTAssertEqual(after.currentUserModificationDates, before.currentUserModificationDates, file: file, line: line)
        XCTAssertEqual(after.files, before.files, file: file, line: line)
        XCTAssertEqual(after.registry, before.registry, file: file, line: line)
        XCTAssertEqual(store.profile(id: profile.id), profile, file: file, line: line)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id, file: file, line: line)
        XCTAssertEqual(store.authenticationRevision, 0, file: file, line: line)
        XCTAssertNil(try store.pendingIdentityReplacement(), file: file, line: line)
    }
}

private final class SecondScopedReadKeychain: KeychainAccessing, @unchecked Sendable {
    private let storage: ServiceKeychain
    private let scopedService: String
    private let mutate: () throws -> Void
    private var scopedReadCount = 0
    private(set) var didMutate = false

    init(storage: ServiceKeychain, scopedService: String, mutate: @escaping () throws -> Void) {
        self.storage = storage
        self.scopedService = scopedService
        self.mutate = mutate
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        if service == scopedService {
            scopedReadCount += 1
            if scopedReadCount == 2 {
                try mutate()
                didMutate = true
            }
        }
        return try storage.readGenericPasswordForCurrentUser(service: service)
    }

    func readGenericPassword(service: String) throws -> String? {
        try storage.readGenericPassword(service: service)
    }

    func writeGenericPassword(service: String, value: String) throws {
        try storage.writeGenericPassword(service: service, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try storage.writeGenericPasswordForCurrentUser(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try storage.deleteGenericPassword(service: service)
    }

    func genericPasswordModificationDate(service: String) throws -> Date? {
        try storage.genericPasswordModificationDate(service: service)
    }

    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date? {
        try storage.genericPasswordModificationDateForCurrentUser(service: service)
    }
}
