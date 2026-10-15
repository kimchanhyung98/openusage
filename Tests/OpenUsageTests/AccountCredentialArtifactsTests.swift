import XCTest
@testable import OpenUsage

final class AccountCredentialArtifactsTests: XCTestCase {
    func testEveryPartialClaudeWriteRestoresAnAbsentOriginalWithoutDeletingLegacyItems() throws {
        for completedWrites in 1...5 {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.keychain.values[fixture.scopedService] = "legacy-scoped"
            fixture.keychain.values[fixture.baseService] = "legacy-base"
            let original = try fixture.artifacts.capture(family: "claude")
            let target = try fixture.artifacts.applying(fixture.target, to: original)

            try fixture.apply(target, first: completedWrites)
            XCTAssertTrue(try fixture.artifacts.canRestore(original, replacing: target))
            try fixture.artifacts.restore(original, replacing: target)

            XCTAssertEqual(try fixture.artifacts.capture(family: "claude"), original)
            XCTAssertEqual(fixture.keychain.values[fixture.scopedService], "legacy-scoped")
            XCTAssertEqual(fixture.keychain.values[fixture.baseService], "legacy-base")
        }
    }

    func testEveryPartialClaudeWriteRestoresIncompleteRawArtifactsAndMetadata() throws {
        for completedWrites in 1...5 {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.keychain.currentUserValues[fixture.scopedService] = " \n"
            fixture.keychain.currentUserValues[fixture.baseService] = ""
            try fixture.write(Data([0xFF, 0xFE, 0x00]), to: fixture.credentialFile)
            try fixture.write(Data("{\n  \"other\": 7\n}\n".utf8), to: fixture.rootState)
            let original = try fixture.artifacts.capture(family: "claude")
            let target = try fixture.artifacts.applying(fixture.target, to: original)

            try fixture.apply(target, first: completedWrites)
            try fixture.artifacts.restore(original, replacing: target)

            XCTAssertEqual(try fixture.artifacts.capture(family: "claude"), original)
        }
    }

    func testExpectedPostimageMatchesActualClaudeAndCodexApplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data(#"{"other":{"keep":true},"oauthAccount":{"accountUuid":"old"}}"#.utf8),
                          to: fixture.rootState)
        for family in ["claude", "codex"] {
            let original = try fixture.artifacts.capture(family: family)
            let target = try fixture.artifacts.applying(fixture.target, to: original)

            try fixture.switcher.applySharedAuthentication(fixture.target, family: family)

            XCTAssertTrue(try fixture.artifacts.matches(target))
            try fixture.artifacts.restore(original, replacing: target)
            XCTAssertEqual(try fixture.artifacts.capture(family: family), original)
        }
    }

    func testForeignKeychainOrFileValueBlocksAllRollbackWrites() throws {
        for changesKeychain in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = try fixture.artifacts.capture(family: "claude")
            let target = try fixture.artifacts.applying(fixture.target, to: original)
            try fixture.apply(target, first: 5)
            if changesKeychain {
                fixture.keychain.currentUserValues[fixture.baseService] = "external-login"
            } else {
                try fixture.write(Data("external-login".utf8), to: fixture.localState)
            }
            let before = try fixture.artifacts.capture(family: "claude")

            XCTAssertFalse(try fixture.artifacts.canRestore(original, replacing: target))
            XCTAssertThrowsError(try fixture.artifacts.restore(original, replacing: target))

            XCTAssertEqual(try fixture.artifacts.capture(family: "claude"), before)
        }
    }

    func testFileWriteBeforePermissionUpdateRestoresOriginalPermissionsAndTimestamp() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent(".codex/auth.json")
        try fixture.write(Data("old-auth".utf8), to: url)
        let original = try fixture.artifacts.capture(family: "codex")
        let target = try fixture.artifacts.applying(fixture.target, to: original)
        try Data(fixture.target.credential.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try fixture.artifacts.restore(original, replacing: target)

        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), original)
    }

    func testSameBytesWrittenByTargetStillRestoreFileMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent(".codex/auth.json")
        try fixture.write(Data(fixture.target.credential.utf8), to: url)
        let original = try fixture.artifacts.capture(family: "codex")
        let target = try fixture.artifacts.applying(fixture.target, to: original)
        try fixture.switcher.applySharedAuthentication(fixture.target, family: "codex")

        try fixture.artifacts.restore(original, replacing: target)

        XCTAssertEqual(try fixture.artifacts.capture(family: "codex"), original)
    }

    func testUnreadableAndInvalidKeychainValuesAbortCaptureWithoutWrites() throws {
        for readError in [KeychainError.readFailed("denied"), .invalidData] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let keychain = ArtifactReadFailureKeychain(error: readError)
            let artifacts = AccountCredentialArtifacts(
                keychain: keychain, environment: FakeEnvironment([:]), homeDirectory: fixture.root
            )

            XCTAssertThrowsError(try artifacts.capture(family: "claude", allowInteraction: false))

            XCTAssertEqual(keychain.nativeReadCount, 1)
            XCTAssertEqual(keychain.otherCallCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootState.path))
        }
    }

    func testRawSnapshotRoundTripsWithoutCredentialParsing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.keychain.currentUserValues[fixture.scopedService] = " \n"
        fixture.keychain.currentUserValues[fixture.baseService] = ""
        try fixture.write(Data([0xFF, 0x00]), to: fixture.credentialFile)
        let captured = try fixture.artifacts.capture(family: "claude")

        let decoded = try JSONDecoder().decode(
            AccountCredentialArtifacts.Snapshot.self, from: JSONEncoder().encode(captured)
        )

        XCTAssertEqual(decoded, captured)
    }

    func testMetadataRestoreFailureLeavesTargetInPlaceAndRetryRestoresOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent(".codex/auth.json")
        try fixture.write(Data("old-auth".utf8), to: url)
        let original = try fixture.artifacts.capture(family: "codex")
        let target = try fixture.artifacts.applying(fixture.target, to: original)
        try fixture.switcher.applySharedAuthentication(fixture.target, family: "codex")
        let fileManager = ArtifactMetadataFailureFileManager()
        let artifacts = AccountCredentialArtifacts(
            keychain: fixture.keychain, fileManager: fileManager,
            environment: fixture.environment, homeDirectory: fixture.root
        )

        XCTAssertThrowsError(try artifacts.restore(original, replacing: target))
        XCTAssertTrue(try artifacts.matches(target))
        XCTAssertEqual(fileManager.temporaryPermissions, 0o600)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            .contains(where: { $0.hasPrefix(".openusage-restore-") }))

        try artifacts.restore(original, replacing: target)

        XCTAssertEqual(try artifacts.capture(family: "codex"), original)
    }

    func testRollbackKeepsNewClaudeSettingsWhenTheOriginalStateFileWasAbsent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.artifacts.capture(family: "claude")
        let applied = try fixture.artifacts.applying(fixture.target, to: original)
        try fixture.apply(applied, first: 5)
        for url in [fixture.rootState, fixture.localState] {
            var state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            state["theme"] = "light"
            try fixture.write(JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]), to: url)
        }

        XCTAssertTrue(try fixture.artifacts.matches(applied))
        try fixture.artifacts.restore(original, replacing: applied)

        XCTAssertTrue(try fixture.artifacts.matches(original))
        for url in [fixture.rootState, fixture.localState] {
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            XCTAssertEqual(state["theme"] as? String, "light")
            XCTAssertNil(state["oauthAccount"])
        }
    }

    private struct Fixture {
        let root: URL
        let keychain = ServiceKeychain()
        let environment = FakeEnvironment([:])
        let target = AccountCredentialVault.Entry(
            credential: #"{"claudeAiOauth":{"accessToken":"target-token"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"target-account","organizationUuid":"target-org"}"#
        )

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("AccountCredentialArtifactsTests-\(UUID().uuidString)")
                .resolvingSymlinksInPath().standardizedFileURL
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        var artifacts: AccountCredentialArtifacts {
            AccountCredentialArtifacts(keychain: keychain, environment: environment, homeDirectory: root)
        }

        var switcher: AccountCredentialSwitcher {
            AccountCredentialSwitcher(keychain: keychain, environment: environment, homeDirectory: root)
        }

        var scopedService: String {
            ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: root.appendingPathComponent(".claude").path, environment: environment
            )
        }

        var baseService: String { ClaudeAuthStore.baseKeychainServiceName(environment: environment) }
        var credentialFile: URL { root.appendingPathComponent(".claude/.credentials.json") }
        var rootState: URL { root.appendingPathComponent(".claude.json") }
        var localState: URL { root.appendingPathComponent(".claude/.claude.json") }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_000)],
                ofItemAtPath: url.path
            )
        }

        func apply(_ target: AccountCredentialArtifacts.Snapshot, first count: Int) throws {
            guard case .claude(let scoped, let base, let credential, let local, let root) = target else {
                return XCTFail("Expected Claude artifacts")
            }
            if count >= 1 { keychain.currentUserValues[scopedService] = scoped }
            if count >= 2 { keychain.currentUserValues[baseService] = base }
            for (index, pair) in [(credentialFile, credential), (rootState, root), (localState, local)].enumerated()
                where count >= index + 3 {
                try write(try XCTUnwrap(pair.1.data), to: pair.0)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pair.0.path)
            }
        }
    }
}

private final class ArtifactReadFailureKeychain: KeychainAccessing, @unchecked Sendable {
    let error: KeychainError
    var nativeReadCount = 0
    var otherCallCount = 0

    init(error: KeychainError) { self.error = error }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        nativeReadCount += 1
        XCTAssertTrue(forCurrentUser)
        XCTAssertFalse(allowInteraction)
        throw error
    }

    func readGenericPassword(service: String) throws -> String? {
        otherCallCount += 1
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws { otherCallCount += 1 }
    func deleteGenericPassword(service: String) throws { otherCallCount += 1 }
}

private final class ArtifactMetadataFailureFileManager: FileManager, @unchecked Sendable {
    var shouldFail = true
    var temporaryPermissions: Int?

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if path.contains(".openusage-restore-"), shouldFail {
            temporaryPermissions = (try attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
            shouldFail = false
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
