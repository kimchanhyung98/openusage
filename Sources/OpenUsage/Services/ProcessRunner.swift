import Foundation
import Darwin

struct ProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

protocol ProcessRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult
}

struct SystemProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        // Debug 전용, basename + arg 개수만 — arg 값에 경로·식별자 포함 가능, 로깅 금지.
        AppLog.debug(.subprocess, "launch \((executable as NSString).lastPathComponent) (\(arguments.count) args)")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // 두 pipe를 child 실행 전 background queue에서 drain 시작 — OS pipe buffer(~64KB) 초과 출력 child의 write blocking·timeout 오작동 방지, exit 후 read는 deadlock.
        let output = SubprocessOutput()
        let drained = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: output, isStdout: true, group: drained)
        drain(stderrPipe.fileHandleForReading, into: output, isStdout: false, group: drained)

        // 50ms poll loop 대신 kernel-level wait 1회 — termination handler를 `run()` 전에 등록해 즉시 종료 child와의 race 차단, `wait`는 exit 또는 deadline까지 1회 blocking.
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            terminateProcessTree(rootPID: process.processIdentifier)
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            drained.wait() // kill된 child가 pipe를 닫아 drain이 EOF로 종료.
            throw ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        }

        process.waitUntilExit()
        drained.wait()
        AppLog.debug(.subprocess, "exit \(process.terminationStatus)")
        return ProcessResult(exitCode: process.terminationStatus, stdout: output.stdoutString, stderr: output.stderrString)
    }

    /// background queue에서 pipe를 EOF까지 read해 `output`에 축적.
    /// child 실행 전 시작으로 pipe 포화 불가 — EOF는 child exit·write end 닫힘 시 도달.
    private func drain(_ handle: FileHandle, into output: SubprocessOutput, isStdout: Bool, group: DispatchGroup) {
        let box = FileHandleBox(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = box.handle.readDataToEndOfFile()
            if isStdout { output.setStdout(data) } else { output.setStderr(data) }
            group.leave()
        }
    }

    private func terminateProcessTree(rootPID: Int32) {
        let children = childPIDs(of: rootPID)
        for child in children {
            terminateProcessTree(rootPID: child)
        }
        kill(rootPID, SIGTERM)
        for child in children {
            kill(child, SIGKILL)
        }
    }

    private func childPIDs(of pid: Int32) -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()
        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            return []
        }

        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}

enum ProcessRunnerError: Error, LocalizedError, Equatable {
    case timedOut(executable: String, timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout))s."
        }
    }
}

/// Swift 6 strict concurrency에서 non-Sendable `FileHandle`을 background drain closure로 전달 — 단일 queue만 read하므로 unchecked 적합.
private final class FileHandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

/// 동시 drain되는 두 pipe의 lock 보호 accumulator.
private final class SubprocessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}

