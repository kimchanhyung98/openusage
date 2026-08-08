import XCTest
@testable import OpenUsage

final class LoginShellEnvironmentTests: XCTestCase {
    private let begin = "__OPENUSAGE_ENV_BEGIN__"
    private let end = "__OPENUSAGE_ENV_END__"

    func testParsesKeysBetweenMarkers() {
        let output = [begin, "OPENROUTER_API_KEY=sk-or-v1-abc", "PATH=/usr/bin:/bin", end]
            .joined(separator: "\0")
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed["OPENROUTER_API_KEY"], "sk-or-v1-abc")
        XCTAssertEqual(parsed["PATH"], "/usr/bin:/bin")
    }

    func testIgnoresBannerOutsideMarkers() {
        // login shell이 명령 전에 출력하는 MOTD/banner는 parse 대상 제외
        let output = ["Welcome to your shell!", "MOTD=should-be-ignored\0" + begin,
                      "REAL=value", end, "trailing-noise"].joined(separator: "\0")
        let parsed = LoginShellEnvironment.parse(output)
        XCTAssertEqual(parsed["REAL"], "value")
        XCTAssertNil(parsed["MOTD"])
    }

    func testKeepsValuesContainingEquals() {
        let output = [begin, "TOKEN=a=b=c", end].joined(separator: "\0")
        XCTAssertEqual(LoginShellEnvironment.parse(output)["TOKEN"], "a=b=c")
    }

    func testMissingMarkersYieldEmpty() {
        XCTAssertTrue(LoginShellEnvironment.parse("PATH=/usr/bin\0HOME=/Users/x").isEmpty)
    }

    func testResolvesKeyOffMainThread() {
        let runner = RecordingRunner(stdout: [begin, "OPENROUTER_API_KEY=sk-or-test", end].joined(separator: "\0"))
        let env = LoginShellEnvironment(runner: runner)
        let captured = expectation(description: "captured off-main")
        var value: String?
        DispatchQueue.global().async {
            value = env.value(for: "OPENROUTER_API_KEY")
            captured.fulfill()
        }
        wait(for: [captured], timeout: 5)
        XCTAssertEqual(value, "sk-or-test")
        XCTAssertEqual(runner.callCount, 1)
    }

    /// cache warm 전 main-thread 읽기는 subprocess spawn·대기 금지 (UI freeze 방지) — prewarm 전까지 nil 반환
    func testMainThreadReadDoesNotRunSubprocess() {
        let runner = RecordingRunner(stdout: [begin, "K=v", end].joined(separator: "\0"))
        let env = LoginShellEnvironment(runner: runner)
        XCTAssertNil(env.value(for: "K"))
        XCTAssertEqual(runner.callCount, 0)
    }
}

/// 고정 stdout 반환 + 호출 횟수 집계 — capture 실행 횟수 검증용
private final class RecordingRunner: ProcessRunning, @unchecked Sendable {
    let stdout: String
    private let lock = NSLock()
    private var count = 0

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> ProcessResult {
        lock.lock(); count += 1; lock.unlock()
        return ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
