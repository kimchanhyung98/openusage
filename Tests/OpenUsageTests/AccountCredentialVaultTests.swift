import Foundation
import Security
import XCTest
@testable import OpenUsage

final class AccountCredentialVaultTests: XCTestCase {
    func testTokenRotationsDoNotRequireSecurityToolApproval() throws {
        let fixture = try AccountVaultKeychainFixture()
        let runner = RejectingVaultProcessRunner()
        let keychain = SecurityKeychainAccessor(
            processRunner: runner,
            passwordWriter: SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path),
            appPasswordReader: SecurityFrameworkGenericPasswordReader(keychainPath: fixture.path)
        )
        let vault = AccountCredentialVault(keychain: keychain)
        let profile = fixture.profile
        var expected = AccountCredentialVault.Entry(
            credential: String(repeating: "한글-token-\n", count: 600),
            claudeOAuthAccount: "account metadata"
        )
        try vault.save(expected, profile: profile)

        for rotation in 1...3 {
            XCTAssertFalse(try fixture.partitions().contains("apple-tool:"))
            XCTAssertEqual(try vault.load(profile: profile), expected)
            expected.credential = "rotation-\(rotation)-" + expected.credential
            try vault.replaceCredential(expected.credential, family: profile.family, profileID: profile.id)
            XCTAssertEqual(try vault.load(profile: profile), expected)
        }
        XCTAssertEqual(runner.callCount, 0)
    }

    func testLegacyServiceOnlySnapshotRemainsReadable() throws {
        let fixture = try AccountVaultKeychainFixture()
        let expected = AccountCredentialVault.Entry(credential: "legacy", claudeOAuthAccount: nil)
        try SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path).write(
            service: fixture.service, account: "Legacy Account", value: try JSONEncoder().encode(expected)
        )
        let runner = RejectingVaultProcessRunner()
        let vault = AccountCredentialVault(keychain: SecurityKeychainAccessor(
            processRunner: runner,
            appPasswordReader: SecurityFrameworkGenericPasswordReader(keychainPath: fixture.path)
        ))

        XCTAssertEqual(try vault.load(profile: fixture.profile), expected)
        XCTAssertEqual(runner.callCount, 0)
    }

    func testBackgroundReadOfUnapprovedItemFailsWithoutLaunchingSecurityTool() throws {
        var previousInteraction: DarwinBoolean = false
        try checkVaultStatus(SecKeychainGetUserInteractionAllowed(&previousInteraction))
        let fixture = try AccountVaultKeychainFixture()
        try fixture.addRestrictedItem(value: Data("synthetic private value".utf8))
        let runner = RejectingVaultProcessRunner()
        let vault = AccountCredentialVault(keychain: SecurityKeychainAccessor(
            processRunner: runner,
            appPasswordReader: SecurityFrameworkGenericPasswordReader(keychainPath: fixture.path)
        ))

        for _ in 1...3 {
            XCTAssertThrowsError(try vault.load(profile: fixture.profile)) { error in
                XCTAssertTrue(error.localizedDescription.contains("refresh manually"))
                XCTAssertFalse(error.localizedDescription.contains(fixture.profile.id))
                XCTAssertFalse(error.localizedDescription.contains("synthetic private value"))
            }
        }
        XCTAssertEqual(runner.callCount, 0)
        var restoredInteraction: DarwinBoolean = false
        try checkVaultStatus(SecKeychainGetUserInteractionAllowed(&restoredInteraction))
        XCTAssertEqual(restoredInteraction.boolValue, previousInteraction.boolValue)
    }

    func testNativeReaderDistinguishesMissingAndInvalidData() throws {
        let fixture = try AccountVaultKeychainFixture()
        let reader = SecurityFrameworkGenericPasswordReader(keychainPath: fixture.path)
        XCTAssertNil(try reader.read(service: fixture.service, account: nil, allowInteraction: false))
        try SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path).write(
            service: fixture.service, account: "Fixture", value: Data([0xFF, 0xFE])
        )
        XCTAssertThrowsError(try reader.read(service: fixture.service, account: nil, allowInteraction: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains(String(errSecDecode)))
        }
    }
}

private final class RejectingVaultProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var callCount = 0

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        callCount += 1
        throw AccountVaultFixtureError.interactiveToolLaunched
    }
}

private final class AccountVaultKeychainFixture {
    let path: String
    let reference: SecKeychain
    let profile = AccountProfile(
        id: UUID().uuidString, family: "codex", label: "Fixture", identityKey: "fixture", createdAt: Date()
    )

    var service: String { AccountCredentialVault.service(family: profile.family, profileID: profile.id) }

    init() throws {
        path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/OpenUsageTests.Vault.\(UUID().uuidString).keychain").path
        let fixturePath = path
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(fixturePath, UInt32(password.utf8.count), $0, false, nil, &created)
        }
        try checkVaultStatus(status)
        reference = try XCTUnwrap(created)
    }

    deinit {
        XCTAssertEqual(SecKeychainDelete(reference), errSecSuccess)
    }

    func addRestrictedItem(value: Data) throws {
        var trustedApplication: SecTrustedApplication?
        try checkVaultStatus(SecTrustedApplicationCreateFromPath("/usr/bin/security", &trustedApplication))
        var access: SecAccess?
        try checkVaultStatus(SecAccessCreate(
            service as CFString, [try XCTUnwrap(trustedApplication)] as CFArray, &access
        ))
        let account = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? NSUserName()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: value,
            kSecUseKeychain as String: reference,
            kSecAttrAccess as String: try XCTUnwrap(access),
        ]
        try checkVaultStatus(SecItemAdd(item as CFDictionary, nil))
    }

    func partitions() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchSearchList as String: [reference],
            kSecReturnRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        try checkVaultStatus(SecItemCopyMatching(query as CFDictionary, &item))
        var access: SecAccess?
        try checkVaultStatus(SecKeychainItemCopyAccess(item as! SecKeychainItem, &access))
        let acls = SecAccessCopyMatchingACLList(try XCTUnwrap(access), kSecACLAuthorizationPartitionID)
            as? [SecACL] ?? []
        return try acls.flatMap { acl in
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            try checkVaultStatus(SecACLCopyContents(acl, &apps, &description, &prompt))
            let hex = Array((try XCTUnwrap(description) as String).utf8)
            var bytes = Data()
            for index in stride(from: 0, to: hex.count, by: 2) {
                bytes.append(try XCTUnwrap(UInt8(String(decoding: hex[index...index + 1], as: UTF8.self), radix: 16)))
            }
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            return try XCTUnwrap(plist?["Partitions"] as? [String])
        }
    }
}

private enum AccountVaultFixtureError: Error {
    case status(OSStatus)
    case interactiveToolLaunched
}

private func checkVaultStatus(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw AccountVaultFixtureError.status(status) }
}
