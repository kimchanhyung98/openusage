import Foundation
import Security
import XCTest

@testable import OpenUsage

final class ClaudeKeychainPersistenceTests: XCTestCase {
    func testCurrentUserTokenRotationsPreserveCLIApproval() throws {
        let account =
            ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? NSUserName()
        try verifyTokenRotations(account: account, forCurrentUser: true)
    }

    func testLegacyTokenRotationsPreserveCLIApproval() throws {
        try verifyTokenRotations(account: "OpenUsage Legacy Fixture", forCurrentUser: false)
    }

    func testSharedWriterPreservesQuotedUnicodeAndNewlinesWithoutSecretArguments() throws {
        try withoutKeychainUI {
            let fixture = try SharedCredentialFixture(account: "Fixture")
            let runner = RecordingWriterRunner()
            let writer = SecurityToolGenericPasswordWriter(keychainPath: fixture.path, processRunner: runner)
            for value in [#"한글 "quote" \slash"#, "first\nsecond"] {
                try writer.write(service: fixture.service, account: fixture.account, value: Data(value.utf8))

                let output = try fixture.cliValue()
                let encoded = value.utf8.map { String(format: "%02x", $0) }.joined()
                XCTAssertTrue(output == value + "\n" || output == encoded + "\n")
            }
            XCTAssertEqual(runner.arguments, [["-i", "-q"], ["-i", "-q"]])
        }
    }

    func testSharedWriterRejectsOverlongInputBeforeChangingStoredCredential() throws {
        try withoutKeychainUI {
            let fixture = try SharedCredentialFixture(account: "Fixture")
            let before = try fixture.cliValue()
            let runner = RecordingWriterRunner()
            let writer = SecurityToolGenericPasswordWriter(keychainPath: fixture.path, processRunner: runner)

            XCTAssertThrowsError(
                try writer.write(
                    service: fixture.service, account: fixture.account, value: Data(repeating: 65, count: 4096)
                ))

            XCTAssertTrue(runner.arguments.isEmpty)
            XCTAssertEqual(try fixture.cliValue(), before)
        }
    }

    func testSharedWriterRejectsAmbiguousLegacyAccountWithoutChangingCredential() throws {
        try withoutKeychainUI {
            let fixture = try SharedCredentialFixture(account: "First")
            let before = try fixture.cliValue()
            try SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path).write(
                service: fixture.service, account: "Second", value: Data("fixture-second".utf8)
            )
            let runner = RecordingWriterRunner()
            let writer = SecurityToolGenericPasswordWriter(keychainPath: fixture.path, processRunner: runner)

            XCTAssertThrowsError(
                try writer.write(
                    service: fixture.service, account: nil, value: Data("replacement".utf8)
                )
            ) { error in
                XCTAssertEqual(error as? GenericPasswordWriteError, .ambiguousService)
            }
            XCTAssertTrue(runner.arguments.isEmpty)
            XCTAssertEqual(try fixture.cliValue(), before)
        }
    }

    private func verifyTokenRotations(account: String, forCurrentUser: Bool) throws {
        var interactionAllowed: DarwinBoolean = false
        try check(SecKeychainGetUserInteractionAllowed(&interactionAllowed))
        try check(SecKeychainSetUserInteractionAllowed(false))
        defer { XCTAssertEqual(SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue), errSecSuccess) }

        let fixture = try SharedCredentialFixture(account: account)
        let accessor = SecurityKeychainAccessor(
            processRunner: FixtureReader(path: fixture.path),
            passwordWriter: SecurityFrameworkGenericPasswordWriter(keychainPath: fixture.path),
            sharedPasswordWriter: SecurityToolGenericPasswordWriter(keychainPath: fixture.path)
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: accessor,
            allowsDesktopFallback: false
        )
        let expectedSource: ClaudeCredentialState.Source =
            forCurrentUser
            ? .keychainCurrentUser(service: fixture.service) : .keychainLegacy(service: fixture.service)

        for rotation in 1...3 {
            var state = try XCTUnwrap(store.loadCredentialCandidates().first)
            XCTAssertEqual(state.source, expectedSource)
            let generation = ClaudeCredentialGeneration([state])
            state.oauth.accessToken = "fixture-access-\(rotation)"
            state.oauth.refreshToken = "fixture-refresh-\(rotation)"
            XCTAssertTrue(try store.save(state, ifUnchanged: generation))

            // 승인 소실 시 CLI secret 재조회 중단 — 실패하는 회귀 테스트도 허용 팝업 생성 금지.
            guard try fixture.partitions().contains("apple-tool:") else {
                XCTFail("Token rotation removed the existing CLI approval")
                return
            }
            let reloaded = try XCTUnwrap(store.loadCredentialCandidates().first)
            XCTAssertEqual(reloaded.oauth.accessToken, state.oauth.accessToken)
            XCTAssertEqual(reloaded.oauth.refreshToken, state.oauth.refreshToken)
        }
    }
}

private final class RecordingWriterRunner: ProcessRunning, @unchecked Sendable {
    private(set) var arguments: [[String]] = []

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        throw FixtureError.unexpectedCommand
    }

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval,
        standardInput: Data
    ) throws -> ProcessResult {
        self.arguments.append(arguments)
        XCTAssertEqual(executable, "/usr/bin/security")
        XCTAssertEqual(arguments, ["-i", "-q"])
        return try SystemProcessRunner().run(
            executable: executable, arguments: arguments, environment: environment, timeout: timeout,
            standardInput: standardInput
        )
    }
}

private struct FixtureReader: ProcessRunning {
    let path: String

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        try SystemProcessRunner().run(
            executable: executable, arguments: arguments + [path], environment: environment, timeout: timeout
        )
    }
}

private final class SharedCredentialFixture {
    let service = "Claude Code-credentials"
    let path: String
    let reference: SecKeychain
    let account: String

    init(account: String) throws {
        self.account = account
        // 이 위치에서 생성해야 운영 login Keychain과 같은 partition ACL을 갖는 형식 사용.
        path =
            FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/OpenUsageTests.Shared.\(UUID().uuidString).keychain").path
        let fixturePath = path
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(fixturePath, UInt32(password.utf8.count), $0, false, nil, &created)
        }
        try check(status)
        reference = try XCTUnwrap(created)
        do {
            let value = #"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh"}}"#
            try SecurityFrameworkGenericPasswordWriter(keychainPath: path).write(
                service: service, account: account, value: Data(value.utf8)
            )
            let original = try partitions()
            XCTAssertFalse(original.isEmpty, "Fixture must use the modern partition ACL format")
            let approved = Set(original + ["apple-tool:"]).sorted()
            let result = try SystemProcessRunner().run(
                executable: "/usr/bin/security",
                arguments: [
                    "set-generic-password-partition-list", "-s", service, "-a", account,
                    "-S", approved.joined(separator: ","), "-k", password, path,
                ],
                environment: [:], timeout: 5
            )
            guard result.succeeded, try partitions().contains("apple-tool:") else {
                throw FixtureError.approvalSetupFailed
            }
        } catch {
            SecKeychainDelete(reference)
            throw error
        }
    }

    deinit {
        XCTAssertEqual(SecKeychainDelete(reference), errSecSuccess, "Fixture Keychain cleanup failed")
    }

    func cliValue() throws -> String {
        guard try partitions().contains("apple-tool:") else { throw FixtureError.approvalSetupFailed }
        let result = try SystemProcessRunner().run(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-s", service, "-a", account, "-w", path],
            environment: [:], timeout: 5
        )
        guard result.succeeded else { throw FixtureError.unexpectedCommand }
        return result.stdout
    }

    func partitions() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [reference], kSecReturnRef as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &item))
        var access: SecAccess?
        try check(SecKeychainItemCopyAccess(item as! SecKeychainItem, &access))
        let acls =
            SecAccessCopyMatchingACLList(try XCTUnwrap(access), kSecACLAuthorizationPartitionID)
            as? [SecACL] ?? []
        return try acls.flatMap { acl in
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            try check(SecACLCopyContents(acl, &apps, &description, &prompt))
            let hex = Array((try XCTUnwrap(description) as String).utf8)
            var bytes = Data()
            for index in stride(from: 0, to: hex.count, by: 2) {
                let pair = String(decoding: hex[index...index + 1], as: UTF8.self)
                bytes.append(try XCTUnwrap(UInt8(pair, radix: 16)))
            }
            let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any]
            return try XCTUnwrap(plist?["Partitions"] as? [String])
        }
    }
}

private enum FixtureError: Error {
    case status(OSStatus)
    case approvalSetupFailed
    case unexpectedCommand
}

private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw FixtureError.status(status) }
}

private func withoutKeychainUI(_ body: () throws -> Void) throws {
    var interactionAllowed: DarwinBoolean = false
    try check(SecKeychainGetUserInteractionAllowed(&interactionAllowed))
    try check(SecKeychainSetUserInteractionAllowed(false))
    defer { XCTAssertEqual(SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue), errSecSuccess) }
    try body()
}
