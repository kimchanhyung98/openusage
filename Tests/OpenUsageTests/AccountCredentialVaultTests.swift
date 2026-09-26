import Foundation
import Security
import XCTest
@testable import OpenUsage

final class AccountCredentialVaultTests: XCTestCase {
    func testTokenRotationsDoNotRequireSecurityToolApproval() throws {
        try withFixture { fixture in
            let runner = RejectingVaultProcessRunner()
            let vault = AccountCredentialVault(keychain: SecurityKeychainAccessor(
                processRunner: runner,
                passwordWriter: SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path),
                appPasswordReader: SecurityFrameworkGenericPasswordReader(keychainPath: fixture.path)
            ))
            var expected = AccountCredentialVault.Entry(
                credential: String(repeating: "한글-token-\n", count: 600),
                claudeOAuthAccount: "account metadata"
            )
            try vault.save(expected, profile: fixture.profile)

            for rotation in 1...3 {
                let partitions = try fixture.partitions()
                XCTAssertFalse(partitions.isEmpty)
                XCTAssertFalse(partitions.contains("apple-tool:"))
                XCTAssertEqual(try vault.load(profile: fixture.profile), expected)
                expected.credential = "rotation-\(rotation)-" + expected.credential
                try vault.replaceCredential(expected.credential, family: fixture.profile.family, profileID: fixture.profile.id)
                XCTAssertEqual(try vault.load(profile: fixture.profile), expected)
            }
            XCTAssertEqual(runner.callCount, 0)
        }
    }

    func testLegacyServiceOnlySnapshotRemainsReadable() throws {
        try withFixture { fixture in
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
    }

    func testNativeReaderDistinguishesMissingAndInvalidData() throws {
        try withFixture { fixture in
            let reader = SecurityFrameworkGenericPasswordReader(keychainPath: fixture.path)
            XCTAssertNil(try reader.read(service: fixture.service, account: nil))
            try SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path).write(
                service: fixture.service, account: "Fixture", value: Data([0xFF, 0xFE])
            )
            XCTAssertThrowsError(try reader.read(service: fixture.service, account: nil)) { error in
                XCTAssertFalse(error.localizedDescription.contains("refresh manually"))
            }
            let keychain = SecurityKeychainAccessor(appPasswordReader: reader)
            XCTAssertThrowsError(try AccountCredentialVault(keychain: keychain).load(profile: fixture.profile)) { error in
                XCTAssertTrue(error is AccountCredentialVaultError)
                XCTAssertTrue(error.localizedDescription.contains("Sign in again"))
            }
            XCTAssertEqual(AccountSignInProbe(keychain: keychain).state(for: fixture.profile), .needsSignIn)
        }
    }

    private func withFixture(_ body: (AccountVaultKeychainFixture) throws -> Void) throws {
        var interactionAllowed: DarwinBoolean = false
        try checkVaultStatus(SecKeychainGetUserInteractionAllowed(&interactionAllowed))
        try checkVaultStatus(SecKeychainSetUserInteractionAllowed(false))
        defer { XCTAssertEqual(SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue), errSecSuccess) }
        let fixture = try AccountVaultKeychainFixture()
        defer { XCTAssertEqual(SecKeychainDelete(fixture.reference), errSecSuccess) }
        try body(fixture)
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
        // 운영 login Keychain과 같은 partition ACL 형식에서 토큰 갱신 후 접근 검증.
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
