import XCTest
import Security
@testable import OpenUsage

final class KeychainAccessorTests: XCTestCase {
    /// 모든 호출에 고정 `ProcessResult` 반환 — 실제 `security` subprocess 없이 exit-code 처리 검증
    private struct StubRunner: ProcessRunning {
        let result: ProcessResult
        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            result
        }
    }

    func testItemNotFoundExitReturnsNil() throws {
        // exit 44(errSecItemNotFound)는 정상적인 "credential 없음" → nil
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain.")
        ))
        XCTAssertNil(try accessor.readGenericPassword(service: "Test"))
    }

    func testNonItemNotFoundFailureThrowsReadFailed() {
        // 44 외 non-zero exit(locked keychain 등)는 throw — nil로 축약되면 "not signed in"으로 오표시
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "User interaction is not allowed.")
        ))
        XCTAssertThrowsError(try accessor.readGenericPassword(service: "Test")) { error in
            guard case KeychainError.readFailed = error else {
                return XCTFail("expected KeychainError.readFailed, got \(error)")
            }
        }
    }

    func testFoundValueIsReturnedTrimmed() throws {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 0, stdout: "secret-token\n", stderr: "")
        ))
        XCTAssertEqual(try accessor.readGenericPassword(service: "Test"), "secret-token")
    }

    func testWritesUseSecurityFrameworkWithoutPuttingSecretsInProcessArguments() throws {
        let runner = RecordingRunner()
        let writer = RecordingPasswordWriter()
        let accessor = SecurityKeychainAccessor(processRunner: runner, passwordWriter: writer)
        let payload = String(repeating: "長-token-\"'\n", count: 80)

        try accessor.writeGenericPassword(service: "Legacy", value: payload)
        try accessor.writeGenericPasswordForCurrentUser(service: "Current", value: payload)

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertEqual(writer.calls.count, 2)
        XCTAssertEqual(writer.calls[0], .init(service: "Legacy", account: nil, value: Data(payload.utf8)))
        let expectedAccount = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? NSUserName()
        XCTAssertEqual(writer.calls[1], .init(service: "Current", account: expectedAccount, value: Data(payload.utf8)))
    }

    func testNativeWriteErrorsAreSanitized() {
        let canary = "SECRET_CANARY"
        let accessor = SecurityKeychainAccessor(
            processRunner: RecordingRunner(),
            passwordWriter: RecordingPasswordWriter(error: .securityStatus(errSecAuthFailed))
        )

        XCTAssertThrowsError(try accessor.writeGenericPassword(service: canary, value: canary)) { error in
            guard case KeychainError.writeFailed(let message) = error else {
                return XCTFail("expected writeFailed, got \(error)")
            }
            XCTAssertFalse(message.contains(canary))
            XCTAssertTrue(message.contains(String(errSecAuthFailed)))
        }
    }

    func testNativeWriterUpdatesOnlyTheSelectedKeychainByPersistentReference() throws {
        let primary = try TemporaryKeychain()
        let secondary = try TemporaryKeychain()
        try primary.add(service: "Shared Service", account: "Shared Account", value: "primary-old")
        try secondary.add(service: "Shared Service", account: "Shared Account", value: "secondary-old")

        try SecurityFrameworkGenericPasswordWriter(keychainPath: primary.path).write(
            service: "Shared Service",
            account: "Shared Account",
            value: Data("primary-new".utf8)
        )

        XCTAssertEqual(try primary.read(service: "Shared Service", account: "Shared Account"), "primary-new")
        XCTAssertEqual(try secondary.read(service: "Shared Service", account: "Shared Account"), "secondary-old")
    }

    func testNativeWriterRejectsMultipleAccountsForAServiceOnlyWrite() throws {
        let keychain = try TemporaryKeychain()
        try keychain.add(service: "Shared Service", account: "First", value: "first")
        try keychain.add(service: "Shared Service", account: "Second", value: "second")

        XCTAssertThrowsError(try SecurityFrameworkGenericPasswordWriter(keychainPath: keychain.path).write(
            service: "Shared Service",
            account: nil,
            value: Data("replacement".utf8)
        )) { error in
            XCTAssertEqual(error as? GenericPasswordWriteError, .ambiguousService)
        }
        XCTAssertEqual(try keychain.read(service: "Shared Service", account: "First"), "first")
        XCTAssertEqual(try keychain.read(service: "Shared Service", account: "Second"), "second")
    }

    /// 큐에 담긴 결과를 순서대로 반환 — repeat-until-not-found delete loop 구동용
    private final class SequenceRunner: ProcessRunning, @unchecked Sendable {
        private var results: [ProcessResult]
        private(set) var callCount = 0

        init(results: [ProcessResult]) {
            self.results = results
        }

        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            callCount += 1
            return results.isEmpty ? ProcessResult(exitCode: 44, stdout: "", stderr: "") : results.removeFirst()
        }
    }

    func testDeletingAMissingItemSucceeds() throws {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain.")
        ))

        XCTAssertNoThrow(try accessor.deleteGenericPassword(service: "Test"))
    }

    func testDeleteRepeatsUntilEveryItemForTheServiceIsGone() throws {
        // 한 service에 account-scoped·unscoped item 공존 가능하고 `security`는 호출당 1개만 삭제
        let runner = SequenceRunner(results: [
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 0, stdout: "", stderr: ""),
            ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain."),
        ])
        let accessor = SecurityKeychainAccessor(processRunner: runner)

        XCTAssertNoThrow(try accessor.deleteGenericPassword(service: "Test"))
        XCTAssertEqual(runner.callCount, 3, "deletion keeps going until not-found proves the service is empty")
    }

    func testDeleteFailureIsReported() {
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 51, stdout: "", stderr: "User interaction is not allowed.")
        ))

        XCTAssertThrowsError(try accessor.deleteGenericPassword(service: "Test")) { error in
            guard case KeychainError.deleteFailed = error else {
                return XCTFail("expected KeychainError.deleteFailed, got \(error)")
            }
        }
    }
}

private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    struct Call: Equatable {
        var executable: String
        var arguments: [String]
    }

    private(set) var calls: [Call] = []

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        calls.append(.init(executable: executable, arguments: arguments))
        return ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }
}

private final class RecordingPasswordWriter: GenericPasswordWriting, @unchecked Sendable {
    struct Call: Equatable {
        var service: String
        var account: String?
        var value: Data
    }

    private(set) var calls: [Call] = []
    private let error: GenericPasswordWriteError?

    init(error: GenericPasswordWriteError? = nil) {
        self.error = error
    }

    func write(service: String, account: String?, value: Data) throws {
        if let error { throw error }
        calls.append(.init(service: service, account: account, value: value))
    }
}

private final class TemporaryKeychain {
    let path: String
    let reference: SecKeychain

    init() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsageTests.Keychain.\(UUID().uuidString).keychain-db")
            .path
        let password = Data(UUID().uuidString.utf8)
        var reference: SecKeychain?
        let status = path.withCString { pathBytes in
            password.withUnsafeBytes { passwordBytes in
                SecKeychainCreate(
                    pathBytes,
                    UInt32(password.count),
                    passwordBytes.baseAddress,
                    false,
                    nil,
                    &reference
                )
            }
        }
        guard status == errSecSuccess, let reference else {
            throw TemporaryKeychainError.status(status)
        }
        self.reference = reference
    }

    deinit {
        SecKeychainDelete(reference)
    }

    func add(service: String, account: String, value: String) throws {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecUseKeychain as String: reference,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw TemporaryKeychainError.status(status) }
    }

    func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [reference],
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw TemporaryKeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private enum TemporaryKeychainError: Error {
        case status(OSStatus)
    }
}
