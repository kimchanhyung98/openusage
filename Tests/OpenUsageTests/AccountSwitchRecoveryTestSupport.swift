import XCTest
@testable import OpenUsage

@MainActor
struct AccountSwitchRecoveryFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let store: AccountProfilesStore
    let keychain: SwitchRecoveryKeychain
    let workspace: AccountSignInWorkspace
    let switcher: AccountCredentialSwitcher
    let a: AccountProfile
    let b: AccountProfile
    let entryA: AccountCredentialVault.Entry
    let entryB: AccountCredentialVault.Entry

    init(test: XCTestCase, synchronize: (() -> Bool)? = nil) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountSwitchRecoveryTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let suite = "AccountSwitchRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = AccountProfilesStore(defaults: defaults, synchronizeDefaults: synchronize)
        let keychain = SwitchRecoveryKeychain()
        let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        let switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment([:]), homeDirectory: root, workspace: workspace
        )
        let a = try store.add(family: "claude", label: "A", identityKey: "acct-a|org-a", id: "profile-a")
        let b = try store.add(family: "claude", label: "B", identityKey: "acct-b|org-b", id: "profile-b")
        let entryA = Self.entry("a")
        let entryB = Self.entry("b")
        for (profile, entry) in [(a, entryA), (b, entryB)] {
            try switcher.saveSnapshot(entry, for: profile)
            try switcher.writeWorkspaceAuthentication(entry, for: profile)
        }
        try switcher.applySharedAuthentication(entryA, family: "claude")
        self.root = root
        self.suite = suite
        self.defaults = defaults
        self.store = store
        self.keychain = keychain
        self.workspace = workspace
        self.switcher = switcher
        self.a = a
        self.b = b
        self.entryA = entryA
        self.entryB = entryB
        test.addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    var importer: AccountCredentialImporter {
        AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment([:]), homeDirectory: root, workspace: workspace
        )
    }

    var selectionSwitcher: AccountSelectionSwitcher { AccountSelectionSwitcher(switcher: switcher) }
    var journal: AccountSwitchJournal { switcher.switchJournal }
    var baseService: String { ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:])) }
    var scopedService: String {
        ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: root.appendingPathComponent(".claude").path,
            environment: FakeEnvironment([:])
        )
    }

    func freshStore() throws -> AccountProfilesStore {
        AccountProfilesStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    func rotateScopedCredentials(replacingRefreshToken: Bool = false) throws -> AccountCredentialVault.Entry {
        let home = root.appendingPathComponent(".claude").path
        let auth = ClaudeAuthStore(
            environment: FakeEnvironment([:]), keychain: keychain,
            scope: .configDir(path: home, keychainLiteral: home), allowsDesktopFallback: false
        )
        let generation = try auth.credentialGeneration()
        var credential = try XCTUnwrap(auth.loadCredentialCandidates().first)
        XCTAssertEqual(credential.source, .keychainCurrentUser(service: scopedService))
        credential.oauth.accessToken = "rotated-access-a"
        if replacingRefreshToken { credential.oauth.refreshToken = "rotated-refresh-a" }
        XCTAssertTrue(try auth.save(credential, ifUnchanged: generation))
        return try XCTUnwrap(switcher.readSharedAuthentication(family: "claude"))
    }

    func stageIntent() throws -> AccountSwitchJournal.Record {
        let record = AccountSwitchJournal.Record(
            previousProfileID: a.id,
            previousIdentity: a.identityKey,
            previousCredentialFingerprint: AccountSwitchJournal.fingerprint(entryA.credential),
            previousStateFingerprint: try switcher.readClaudeSwitchState().fingerprint(),
            selectedProfileID: b.id,
            selectedIdentity: b.identityKey,
            selectedCredentialFingerprint: AccountSwitchJournal.fingerprint(entryB.credential)
        )
        try journal.save(record, replacing: nil)
        return record
    }

    func assertSavedAccountsUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
        for (profile, entry) in [(a, entryA), (b, entryB)] {
            XCTAssertEqual(try switcher.loadSnapshot(for: profile), entry, file: file, line: line)
            let home = try workspace.directory(family: "claude", profileID: profile.id).path
            XCTAssertEqual(try switcher.readAuthentication(family: "claude", home: home), entry, file: file, line: line)
            XCTAssertEqual(try freshStore().profile(id: profile.id)?.identityKey, profile.identityKey, file: file, line: line)
        }
    }

    static func entry(_ suffix: String, token: String? = nil) -> AccountCredentialVault.Entry {
        let token = token ?? "token-\(suffix)"
        return .init(
            credential: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(token)"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-\#(suffix)","organizationUuid":"org-\#(suffix)"}"#
        )
    }
}

final class SwitchRecoveryKeychain: KeychainAccessing, @unchecked Sendable {
    enum Failure: Error { case injected }

    private struct State {
        var values: [String: String] = [:]
        var currentUserValues: [String: String] = [:]
        var currentUserModificationDates: [String: Date] = [:]
        var writeCount = 0
        var readFailureService: String?
        var beforeRead: (@Sendable (String) throws -> Void)?
        var beforeWrite: ((String, String) throws -> Void)?
    }

    private let lock = NSLock()
    private var state = State()

    var values: [String: String] {
        get { lock.withLock { state.values } }
        set { lock.withLock { state.values = newValue } }
    }

    var currentUserValues: [String: String] {
        get { lock.withLock { state.currentUserValues } }
        set { lock.withLock { state.currentUserValues = newValue } }
    }

    var currentUserModificationDates: [String: Date] {
        get { lock.withLock { state.currentUserModificationDates } }
        set { lock.withLock { state.currentUserModificationDates = newValue } }
    }

    var writeCount: Int { lock.withLock { state.writeCount } }

    var readFailureService: String? {
        get { lock.withLock { state.readFailureService } }
        set { lock.withLock { state.readFailureService = newValue } }
    }

    var beforeRead: (@Sendable (String) throws -> Void)? {
        get { lock.withLock { state.beforeRead } }
        set { lock.withLock { state.beforeRead = newValue } }
    }

    var beforeWrite: ((String, String) throws -> Void)? {
        get { lock.withLock { state.beforeWrite } }
        set { lock.withLock { state.beforeWrite = newValue } }
    }

    func readGenericPassword(service: String) throws -> String? {
        try beforeRead?(service)
        return try lock.withLock {
            if service == state.readFailureService { throw Failure.injected }
            return state.values[service]
        }
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try beforeRead?(service)
        return try lock.withLock {
            if service == state.readFailureService { throw Failure.injected }
            return state.currentUserValues[service]
        }
    }

    func writeGenericPassword(service: String, value: String) throws {
        try beforeWrite?(service, value)
        lock.withLock {
            state.writeCount += 1
            state.values[service] = value
        }
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try beforeWrite?(service, value)
        lock.withLock {
            state.writeCount += 1
            state.currentUserValues[service] = value
            state.currentUserModificationDates[service] = Date()
        }
    }

    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date? {
        currentUserModificationDates[service]
    }

    func deleteGenericPassword(service: String) throws {
        lock.withLock {
            state.values.removeValue(forKey: service)
            state.currentUserValues.removeValue(forKey: service)
        }
    }
}

final class SwitchJournalFiles: TextFileAccessing, @unchecked Sendable {
    private let local = LocalTextFileAccessor()
    var failRead = false
    var failWrite = false
    var failRemove = false

    func exists(_ path: String) -> Bool { local.exists(path) }
    func readText(_ path: String) throws -> String {
        if failRead { throw SwitchRecoveryKeychain.Failure.injected }
        return try local.readText(path)
    }
    func readTextIfPresent(_ path: String) throws -> String? {
        if failRead { throw SwitchRecoveryKeychain.Failure.injected }
        return try local.readTextIfPresent(path)
    }
    func writeText(_ path: String, _ text: String) throws {
        if failWrite { throw SwitchRecoveryKeychain.Failure.injected }
        try local.writeText(path, text)
    }
    func remove(_ path: String) throws {
        if failRemove { throw SwitchRecoveryKeychain.Failure.injected }
        try local.remove(path)
    }
}

final class SwitchRecoveryReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let started: XCTestExpectation
    private let resume = DispatchSemaphore(value: 0)
    private var isArmed = true

    init(started: XCTestExpectation) {
        self.started = started
    }

    func pauseOnce() throws {
        let shouldPause = lock.withLock {
            guard isArmed else { return false }
            isArmed = false
            return true
        }
        guard shouldPause else { return }
        started.fulfill()
        guard resume.wait(timeout: .now() + 5) == .success else {
            throw SwitchRecoveryKeychain.Failure.injected
        }
    }

    func release() {
        resume.signal()
    }
}

@MainActor
func assertSwitchFails(
    _ operation: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("The account switch should fail.", file: file, line: line)
    } catch {}
}
