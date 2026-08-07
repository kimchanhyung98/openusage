import XCTest
@testable import OpenUsage

final class KeychainAccessorTests: XCTestCase {
    /// Returns a fixed `ProcessResult` for any invocation — lets us drive the accessor's exit-code
    /// handling without a real `security` subprocess.
    private struct StubRunner: ProcessRunning {
        let result: ProcessResult
        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
            result
        }
    }

    func testItemNotFoundExitReturnsNil() throws {
        // Exit 44 (errSecItemNotFound) is the legitimate "no credential stored" case → nil.
        let accessor = SecurityKeychainAccessor(processRunner: StubRunner(
            result: ProcessResult(exitCode: 44, stdout: "", stderr: "The specified item could not be found in the keychain.")
        ))
        XCTAssertNil(try accessor.readGenericPassword(service: "Test"))
    }

    func testNonItemNotFoundFailureThrowsReadFailed() {
        // A non-44 non-zero exit (locked keychain / access denied / cancelled unlock) must throw, not
        // collapse into the same nil as "no credential" — otherwise it gets mislabeled "not signed in".
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

    /// Returns queued results in order — drives the accessor's repeat-until-not-found delete loop.
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
        // A service can hold both an account-scoped and an unscoped item; `security` removes one
        // per call, so a single delete would leave a removed account's token behind.
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
