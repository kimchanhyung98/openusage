import XCTest
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
