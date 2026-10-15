import XCTest
@testable import OpenUsage

@MainActor
final class AccountIdentityReplacementRollbackTests: XCTestCase {
    func testPartialReSignInRollbackRecoversAfterRestart() async throws {
        let fixture = try Fixture(family: "claude")
        defer { fixture.cleanup() }
        let previous = fixture.entry(account: "a", token: "old")
        let target = fixture.entry(account: "b", token: "target")
        try fixture.switcher.saveSnapshot(previous, for: fixture.profile)
        try fixture.switcher.applySharedAuthentication(previous, family: "claude")
        try fixture.switcher.writeWorkspaceAuthentication(target, for: fixture.profile)
        let scoped = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: fixture.root.appendingPathComponent(".claude").path,
            environment: FakeEnvironment()
        )
        let base = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())
        fixture.keychain.failOnWrite = [base: 1, scoped: 2]

        XCTAssertThrowsError(try fixture.importer.completeReSignIn(
            profileID: fixture.profile.id, in: fixture.store, isActive: true
        ))

        XCTAssertEqual(fixture.keychain.failureCount, 2)
        XCTAssertEqual(fixture.keychain.storage.currentUserValues[scoped], target.credential)
        XCTAssertEqual(fixture.keychain.storage.currentUserValues[base], previous.credential)
        let pending = try XCTUnwrap(fixture.store.pendingIdentityReplacement())
        let restarted = AccountProfilesStore(defaults: fixture.defaults)

        let result = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: restarted)

        XCTAssertEqual(result, .recoveredAuthentication)
        let snapshot = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.profile))
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), snapshot)
        XCTAssertEqual(try fixture.importer.readWorkspaceCredential(
            family: "claude", profileID: fixture.profile.id
        )?.entry, snapshot)
        XCTAssertEqual(fixture.keychain.storage.currentUserValues[scoped], snapshot.credential)
        XCTAssertEqual(fixture.keychain.storage.currentUserValues[base], snapshot.credential)
        XCTAssertEqual(restarted.profile(id: fixture.profile.id)?.identityKey,
                       fixture.switcher.identity(of: snapshot, family: "claude")?.identityKey)
        XCTAssertNil(try restarted.pendingIdentityReplacement())
        XCTAssertNotNil(pending.replacementSnapshotDigest)
        XCTAssertNotNil(pending.originalSharedAuthenticationDigest)
    }

    func testPartialRollbackMustRetainJournalUntilSharedAuthenticationIsRestored() throws {
        let fixture = try Fixture(family: "codex")
        defer { fixture.cleanup() }
        let previous = fixture.entry(account: "a", token: "old")
        let target = fixture.entry(account: "b", token: "target")
        let transaction = try fixture.store.beginIdentityReplacement(
            profileID: fixture.profile.id, with: "acct-b", replacesSharedAuthentication: true,
            replacementSnapshotDigest: target.snapshotDigest()
        )
        // rollback의 snapshot/workspace 복원 성공 후 shared 복원만 실패한 재시작 상태.
        try fixture.switcher.saveSnapshot(previous, for: fixture.profile)
        try fixture.switcher.writeWorkspaceAuthentication(previous, for: fixture.profile)
        try fixture.switcher.applySharedAuthentication(target, family: "codex")
        let reloaded = AccountProfilesStore(defaults: fixture.defaults)
        XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), previous)
        XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "acct-a")
        let shared = try fixture.switcher.readSharedAuthentication(family: "codex")
        let remaining = try reloaded.pendingIdentityReplacement()
        XCTAssertEqual(shared, target)
        XCTAssertEqual(remaining, transaction)
    }

    func testUnreadableSwitchRecoveryRecordReportsBothManagedFamiliesWithoutDeletingIt() async throws {
        let fixture = try Fixture(family: "codex")
        defer { fixture.cleanup() }
        let unreadable = "incomplete-switch-journal"
        fixture.keychain.storage.currentUserValues[AccountSwitchJournal.service] = unreadable
        do {
            _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
            XCTFail("Expected the unreadable recovery record to block reconciliation")
        } catch {
            XCTAssertEqual(error as? AccountSwitchJournal.Error, .invalidRecord)
        }

        let failure = await fixture.importer.reconciliationFailure(
            for: AccountSwitchJournal.Error.invalidRecord, in: fixture.store
        )

        XCTAssertEqual(failure.families, ["claude", "codex"])
        XCTAssertEqual(fixture.keychain.storage.currentUserValues[AccountSwitchJournal.service], unreadable)
    }

    func testUndecodableIdentityJournalReportsBothFamiliesAfterTheFailedReadRemovesIt() async throws {
        let fixture = try Fixture(family: "codex")
        defer { fixture.cleanup() }
        fixture.defaults.set(Data("incomplete-identity-journal".utf8),
                             forKey: AccountProfilesStore.identityReplacementKey)
        var failure: AccountCredentialImporter.ReconciliationFailure?
        do {
            _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
            XCTFail("Expected the unreadable identity journal to block reconciliation")
        } catch {
            failure = await fixture.importer.reconciliationFailure(for: error, in: fixture.store)
        }

        XCTAssertEqual(try XCTUnwrap(failure).families, ["claude", "codex"])
        XCTAssertNil(fixture.defaults.data(forKey: AccountProfilesStore.identityReplacementKey))
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let store: AccountProfilesStore
        let profile: AccountProfile
        let switcher: AccountCredentialSwitcher
        let importer: AccountCredentialImporter
        let keychain = RollbackFailingKeychain()

        init(family: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountIdentityReplacementRollbackTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            suite = "AccountIdentityReplacementRollbackTests-\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("SignIn"))
            switcher = AccountCredentialSwitcher(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
            importer = AccountCredentialImporter(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
            )
            store = AccountProfilesStore(defaults: defaults)
            profile = try store.add(
                family: family, label: "Work",
                identityKey: family == "claude" ? "acct-a|org-a" : "acct-a", id: "profile-a"
            )
        }

        func entry(account: String, token: String) -> AccountCredentialVault.Entry {
            if profile.family == "codex" {
                return .init(credential: #"{"tokens":{"access_token":"\#(token)","account_id":"acct-\#(account)"}}"#, claudeOAuthAccount: nil)
            }
            return .init(
                credential: #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(token)"}}"#,
                claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
            )
        }

        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class RollbackFailingKeychain: KeychainAccessing, @unchecked Sendable {
    enum Failure: Error { case injected }

    let storage = ServiceKeychain()
    var failOnWrite: [String: Int] = [:]
    private var writeCounts: [String: Int] = [:]
    private(set) var failureCount = 0

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        forCurrentUser ? storage.currentUserValues[service] : storage.values[service]
    }
    func readGenericPassword(service: String) throws -> String? { try storage.readGenericPassword(service: service) }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { try storage.readGenericPasswordForCurrentUser(service: service) }
    func genericPasswordExists(service: String) -> Bool? { storage.genericPasswordExists(service: service) }
    func writeGenericPassword(service: String, value: String) throws { try storage.writeGenericPassword(service: service, value: value) }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        if let target = failOnWrite[service] {
            writeCounts[service, default: 0] += 1
            if writeCounts[service] == target {
                failureCount += 1
                throw Failure.injected
            }
        }
        try storage.writeGenericPasswordForCurrentUser(service: service, value: value)
    }
    func deleteGenericPassword(service: String) throws { try storage.deleteGenericPassword(service: service) }
    func deleteGenericPasswordForCurrentUser(service: String) throws { try storage.deleteGenericPasswordForCurrentUser(service: service) }
    func genericPasswordModificationDate(service: String) throws -> Date? { try storage.genericPasswordModificationDate(service: service) }
    func genericPasswordModificationDateForCurrentUser(service: String) throws -> Date? { try storage.genericPasswordModificationDateForCurrentUser(service: service) }
}
