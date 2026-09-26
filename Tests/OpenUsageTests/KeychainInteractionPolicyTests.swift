import Foundation
import Security
import XCTest
@testable import OpenUsage

final class KeychainInteractionPolicyTests: XCTestCase {
    func testInteractionPolicyIsScopedAndRestoredAfterSuccessAndFailure() throws {
        var original: DarwinBoolean = false
        try checkPolicyStatus(SecKeychainGetUserInteractionAllowed(&original))
        defer { XCTAssertEqual(SecKeychainSetUserInteractionAllowed(original.boolValue), errSecSuccess) }

        for initiallyAllowed in [true, false] {
            try checkPolicyStatus(SecKeychainSetUserInteractionAllowed(initiallyAllowed))
            for requested in [false, true] {
                for fails in [false, true] {
                    let reader = InteractionCheckingReader(expected: initiallyAllowed && requested, fails: fails)
                    if fails {
                        XCTAssertThrowsError(try reader.read(service: "fixture", account: nil, allowInteraction: requested))
                    } else {
                        XCTAssertEqual(try reader.read(service: "fixture", account: nil, allowInteraction: requested), "fixture")
                    }
                    var restored: DarwinBoolean = false
                    try checkPolicyStatus(SecKeychainGetUserInteractionAllowed(&restored))
                    XCTAssertEqual(restored.boolValue, initiallyAllowed)
                }
            }
        }
    }

    func testBackgroundReadOfUnapprovedItemFailsWithoutLaunchingSecurityTool() throws {
        var previousInteraction: DarwinBoolean = false
        try checkPolicyStatus(SecKeychainGetUserInteractionAllowed(&previousInteraction))
        let fixture = try makeFixture()
        try fixture.addRestrictedItem(value: Data("synthetic private value".utf8))
        let runner = RejectingPolicyProcessRunner()
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
        try checkPolicyStatus(SecKeychainGetUserInteractionAllowed(&restoredInteraction))
        XCTAssertEqual(restoredInteraction.boolValue, previousInteraction.boolValue)
    }

    func testNativeWritesWaitForOtherKeychainOperations() throws {
        let fixture = try makeFixture()
        let started = expectation(description: "writer started")
        let finished = expectation(description: "writer finished")
        let completed = DispatchSemaphore(value: 0)
        let fixturePath = fixture.path
        let service = fixture.service
        do {
            try NativeKeychainAccess.acquire()
            defer { NativeKeychainAccess.release() }
            DispatchQueue.global().async {
                started.fulfill()
                do {
                    try SecurityFrameworkGenericPasswordWriter(keychainPath: fixturePath).write(
                        service: service, account: "Fixture", value: Data("credential".utf8)
                    )
                } catch { XCTFail("Write failed: \(error)") }
                completed.signal()
                finished.fulfill()
            }
            wait(for: [started], timeout: 3)
            XCTAssertEqual(completed.wait(timeout: .now() + 0.2), .timedOut)
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try SecurityFrameworkGenericPasswordReader(keychainPath: fixturePath).read(
            service: service, account: "Fixture", allowInteraction: false
        ), "credential")
    }

    func testExistenceProbeDoesNotWaitForPendingKeychainOperation() throws {
        let finished = expectation(description: "existence probe returned unknown")
        try NativeKeychainAccess.acquire()
        defer { NativeKeychainAccess.release() }
        DispatchQueue.global().async {
            XCTAssertNil(SecurityKeychainAccessor().genericPasswordExists(service: "OpenUsageTests.PendingProbe"))
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
    }

    func testPendingKeychainOperationBoundsReadsAndWritesWithAnAccessError() throws {
        let fixture = try makeFixture()
        let finished = expectation(description: "blocked operations failed")
        finished.expectedFulfillmentCount = 2
        let fixturePath = fixture.path
        let operations: [@Sendable () throws -> Void] = [
            {
                _ = try SecurityFrameworkGenericPasswordReader(keychainPath: fixturePath).read(
                    service: "fixture", account: nil, allowInteraction: false
                )
            },
            {
                try SecurityKeychainAccessor(
                    passwordWriter: SecurityFrameworkGenericPasswordWriter(keychainPath: fixturePath)
                ).writeGenericPassword(service: "fixture", value: "credential")
            },
        ]
        try NativeKeychainAccess.acquire()
        defer { NativeKeychainAccess.release() }
        for operation in operations {
            DispatchQueue.global().async {
                do {
                    try operation()
                    XCTFail("Expected a bounded wait")
                } catch {
                    guard case KeychainError.accessBusy = error else {
                        XCTFail("Expected an access error, got \(error)")
                        finished.fulfill()
                        return
                    }
                    XCTAssertTrue(error.localizedDescription.contains("Keychain is busy"))
                }
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 10)
    }

    private func makeFixture() throws -> PolicyKeychainFixture {
        let fixture = try PolicyKeychainFixture()
        addTeardownBlock { try fixture.close() }
        return fixture
    }
}

private struct InteractionCheckingReader: GenericPasswordReading {
    let expected: Bool
    let fails: Bool

    func read(service: String, account: String?) throws -> String? {
        var allowed: DarwinBoolean = false
        try checkPolicyStatus(SecKeychainGetUserInteractionAllowed(&allowed))
        XCTAssertEqual(allowed.boolValue, expected)
        if fails { throw KeychainError.readFailed("Fixture read failed.") }
        return "fixture"
    }
}

private final class RejectingPolicyProcessRunner: ProcessRunning, @unchecked Sendable {
    private(set) var callCount = 0

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        callCount += 1
        throw PolicyFixtureError.interactiveToolLaunched
    }
}

private final class PolicyKeychainFixture: @unchecked Sendable {
    let path: String
    let reference: SecKeychain
    let profile = AccountProfile(
        id: UUID().uuidString, family: "codex", label: "Fixture", identityKey: "fixture", createdAt: Date()
    )

    var service: String { AccountCredentialVault.service(family: profile.family, profileID: profile.id) }

    init() throws {
        path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains/OpenUsageTests.Policy.\(UUID().uuidString).keychain").path
        let fixturePath = path
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = password.withCString {
            SecKeychainCreate(fixturePath, UInt32(password.utf8.count), $0, false, nil, &created)
        }
        try checkPolicyStatus(status)
        reference = try XCTUnwrap(created)
    }

    func close() throws {
        try checkPolicyStatus(SecKeychainDelete(reference))
    }

    func addRestrictedItem(value: Data) throws {
        var trustedApplication: SecTrustedApplication?
        try checkPolicyStatus(SecTrustedApplicationCreateFromPath("/usr/bin/security", &trustedApplication))
        var access: SecAccess?
        try checkPolicyStatus(SecAccessCreate(
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
        try checkPolicyStatus(SecItemAdd(item as CFDictionary, nil))
    }
}

private enum PolicyFixtureError: Error {
    case status(OSStatus)
    case interactiveToolLaunched
}

private func checkPolicyStatus(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw PolicyFixtureError.status(status) }
}
