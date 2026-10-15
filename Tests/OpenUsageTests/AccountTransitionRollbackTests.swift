import Foundation
import XCTest
@testable import OpenUsage

final class AccountTransitionRollbackTests: XCTestCase {
    func testFailedFirstClaudeSwitchRemovesPartiallyWrittenSharedCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountTransitionRollback.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.resolvingSymlinksInPath().standardizedFileURL
        let sharedHome = home.appendingPathComponent(".claude")
        let environment = FakeEnvironment()
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome.path, environment: environment
        )
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let keychain = PartialClaudeWriteKeychain(scopedService: scopedService, failingService: baseService)
        let vault = AccountCredentialVault(keychain: keychain)
        let profile = AccountProfile(
            id: "target", family: "claude", label: "Work",
            identityKey: "acct-b|org-b", createdAt: .distantPast
        )
        let target = AccountCredentialVault.Entry(
            credential: #"{"claudeAiOauth":{"accessToken":"target-access","refreshToken":"target-refresh"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-b","organizationUuid":"org-b","emailAddress":"b@example.com"}"#
        )
        try vault.save(target, profile: profile)
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: environment,
            homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        )
        XCTAssertNil(try switcher.readSharedAuthentication(family: "claude"))
        XCTAssertNil(try keychain.readGenericPasswordForCurrentUser(service: scopedService))
        XCTAssertNil(try keychain.readGenericPasswordForCurrentUser(service: baseService))

        XCTAssertThrowsError(try switcher.switchAuthentication(to: profile, from: nil)) { error in
            XCTAssertEqual(error as? PartialClaudeWriteKeychain.WriteFailure, .baseWrite)
        }

        XCTAssertEqual(keychain.scopedCredentialAtFailure, target.credential)
        XCTAssertNil(try keychain.readGenericPasswordForCurrentUser(service: scopedService))
        XCTAssertNil(try keychain.readGenericPasswordForCurrentUser(service: baseService))
        XCTAssertNil(try keychain.readGenericPassword(service: scopedService))
        XCTAssertNil(try keychain.readGenericPassword(service: baseService))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedHome.appendingPathComponent(".credentials.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedHome.appendingPathComponent(".claude.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude.json").path))
        XCTAssertEqual(try vault.load(profile: profile), target)
    }

    func testFailedClaudeSwitchRestoresUnusableKeychainValuesWithoutChangingRawFiles() throws {
        let fixture = try makePartialFixture(failBaseWrite: true, failLocalStateWrite: false)
        XCTAssertNil(try fixture.switcher.readSharedAuthentication(family: "claude"))

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: fixture.profile, from: nil)) { error in
            XCTAssertEqual(error as? PartialClaudeWriteKeychain.WriteFailure, .baseWrite)
        }

        XCTAssertEqual(fixture.keychain.scopedCredentialAtFailure, fixture.target.credential)
        try assertPartialAuthenticationRestored(fixture)
    }

    func testFailedClaudeStateWriteRestoresRawCredentialsAndBothStateFiles() throws {
        let fixture = try makePartialFixture(failBaseWrite: false, failLocalStateWrite: true)
        XCTAssertNil(try fixture.switcher.readSharedAuthentication(family: "claude"))

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: fixture.profile, from: nil)) { error in
            XCTAssertEqual(error as? PartialClaudeFileManager.WriteFailure, .localStateAttributes)
        }

        let filesAtFailure = try XCTUnwrap(fixture.fileManager.filesAtFailure)
        let credentialURL = fixture.home.appendingPathComponent(".claude/.credentials.json")
        XCTAssertEqual(filesAtFailure[credentialURL], Data(fixture.target.credential.utf8))
        for relativePath in [".claude.json", ".claude/.claude.json"] {
            let url = fixture.home.appendingPathComponent(relativePath)
            let data = try XCTUnwrap(filesAtFailure[url])
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual((state["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-b")
            XCTAssertNotEqual(data, fixture.originalFiles[url])
        }
        try assertPartialAuthenticationRestored(fixture)
    }

    private struct PartialFixture {
        let home: URL
        let keychain: PartialClaudeWriteKeychain
        let fileManager: PartialClaudeFileManager
        let switcher: AccountCredentialSwitcher
        let profile: AccountProfile
        let target: AccountCredentialVault.Entry
        let originalCurrentUserValues: [String: String]
        let originalGeneralValues: [String: String]
        let originalFiles: [URL: Data]
    }

    private func makePartialFixture(failBaseWrite: Bool, failLocalStateWrite: Bool) throws -> PartialFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.AccountTransitionRollback.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.resolvingSymlinksInPath().standardizedFileURL
        let sharedHome = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        let environment = FakeEnvironment()
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome.path, environment: environment
        )
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let currentUserValues = [
            scopedService: " {\"claudeAiOauth\":{\"refreshToken\":\"orphan-scoped-refresh\"}}\n",
            baseService: #"{"claudeAiOauth":{"accessToken":""}}"#,
        ]
        let generalValues = [
            scopedService: "{partial-scoped",
            baseService: #"{"claudeAiOauth":null,"keep":"base-legacy"}"#,
        ]
        let originalFiles = [
            sharedHome.appendingPathComponent(".credentials.json"):
                Data(" {\"claudeAiOauth\":{\"refreshToken\":\"orphan-file-refresh\"},\"extra\":\"keep-file\"}\n".utf8),
            home.appendingPathComponent(".claude.json"):
                Data("{\n  \"memory\": \"keep-root\", \"oauthAccount\": {\"emailAddress\":\"partial@example.com\"}\n}\n".utf8),
            sharedHome.appendingPathComponent(".claude.json"):
                Data("{\n  \"projects\": {\"/tmp/project\": {\"allowedTools\": [\"Read\"]}}, \"theme\": \"dark\"\n}\n".utf8),
        ]
        for (url, data) in originalFiles {
            try data.write(to: url)
        }
        let fileManager = PartialClaudeFileManager(
            failingPath: failLocalStateWrite ? sharedHome.appendingPathComponent(".claude.json").path : nil,
            observedFiles: Array(originalFiles.keys)
        )
        let keychain = PartialClaudeWriteKeychain(
            scopedService: scopedService,
            failingService: failBaseWrite ? baseService : nil,
            values: generalValues,
            currentUserValues: currentUserValues
        )
        let profile = AccountProfile(
            id: "target", family: "claude", label: "Work",
            identityKey: "acct-b|org-b", createdAt: .distantPast
        )
        let target = AccountCredentialVault.Entry(
            credential: #"{"claudeAiOauth":{"accessToken":"target-access","refreshToken":"target-refresh"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-b","organizationUuid":"org-b","emailAddress":"b@example.com"}"#
        )
        try AccountCredentialVault(keychain: keychain).save(target, profile: profile)
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: home,
            workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("SignIn"))
        )
        return PartialFixture(
            home: home, keychain: keychain, fileManager: fileManager, switcher: switcher,
            profile: profile, target: target, originalCurrentUserValues: currentUserValues,
            originalGeneralValues: generalValues, originalFiles: originalFiles
        )
    }

    private func assertPartialAuthenticationRestored(
        _ fixture: PartialFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (service, value) in fixture.originalCurrentUserValues {
            XCTAssertEqual(try fixture.keychain.readGenericPasswordForCurrentUser(service: service), value, file: file, line: line)
        }
        for (service, value) in fixture.originalGeneralValues {
            XCTAssertEqual(try fixture.keychain.readGenericPassword(service: service), value, file: file, line: line)
        }
        for (url, data) in fixture.originalFiles {
            XCTAssertEqual(try Data(contentsOf: url), data, url.lastPathComponent, file: file, line: line)
        }
        XCTAssertNil(try fixture.switcher.readSharedAuthentication(family: "claude"), file: file, line: line)
        XCTAssertEqual(
            try AccountCredentialVault(keychain: fixture.keychain).load(profile: fixture.profile),
            fixture.target, file: file, line: line
        )
    }
}

private final class PartialClaudeWriteKeychain: KeychainAccessing, @unchecked Sendable {
    enum WriteFailure: Error, Equatable {
        case baseWrite
    }

    private let storage: ServiceKeychain
    private let scopedService: String
    private let failingService: String?
    private var hasFailed = false
    private(set) var scopedCredentialAtFailure: String?

    init(
        scopedService: String,
        failingService: String?,
        values: [String: String] = [:],
        currentUserValues: [String: String] = [:]
    ) {
        self.scopedService = scopedService
        self.failingService = failingService
        storage = ServiceKeychain(values: values, currentUserValues: currentUserValues)
    }

    func readGenericPassword(service: String) throws -> String? {
        try storage.readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try storage.readGenericPasswordForCurrentUser(service: service)
    }

    func genericPasswordExists(service: String) -> Bool? {
        storage.values[service] != nil || storage.currentUserValues[service] != nil
    }

    func writeGenericPassword(service: String, value: String) throws {
        try storage.writeGenericPassword(service: service, value: value)
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        if service == failingService, !hasFailed {
            hasFailed = true
            scopedCredentialAtFailure = try storage.readGenericPasswordForCurrentUser(service: scopedService)
            throw WriteFailure.baseWrite
        }
        try storage.writeGenericPasswordForCurrentUser(service: service, value: value)
    }

    func deleteGenericPassword(service: String) throws {
        try storage.deleteGenericPassword(service: service)
    }

    func deleteGenericPasswordForCurrentUser(service: String) throws {
        storage.currentUserValues.removeValue(forKey: service)
        storage.currentUserModificationDates.removeValue(forKey: service)
    }
}

private final class PartialClaudeFileManager: FileManager, @unchecked Sendable {
    enum WriteFailure: Error, Equatable {
        case localStateAttributes
    }

    private let failingPath: String?
    private let observedFiles: [URL]
    private(set) var filesAtFailure: [URL: Data]?

    init(failingPath: String?, observedFiles: [URL]) {
        self.failingPath = failingPath
        self.observedFiles = observedFiles
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path == failingPath, filesAtFailure == nil {
            filesAtFailure = try Dictionary(uniqueKeysWithValues: observedFiles.map { url in
                (url, try Data(contentsOf: url))
            })
            throw WriteFailure.localStateAttributes
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
