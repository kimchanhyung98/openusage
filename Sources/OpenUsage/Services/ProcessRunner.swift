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
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        standardInput: Data
    ) throws -> ProcessResult
}

extension ProcessRunning {
    func run(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval, standardInput: Data
    ) throws -> ProcessResult {
        throw ProcessRunnerError.standardInputUnsupported
    }
}

struct SystemProcessRunner: ProcessRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        try execute(
            executable: executable, arguments: arguments, environment: environment,
            timeout: timeout, standardInput: nil)
    }

    /// 표준 입력은 최대 4,096바이트. 초과 입력은 프로세스 실행 전 거부.
    func run(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval, standardInput: Data
    ) throws -> ProcessResult {
        guard standardInput.count <= 4_096 else {
            throw ProcessRunnerError.standardInputTooLarge
        }
        return try execute(
            executable: executable, arguments: arguments, environment: environment,
            timeout: timeout, standardInput: standardInput)
    }

    private func execute(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval, standardInput: Data?
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
        let stdinPipe = standardInput.map { _ in Pipe() }
        if let stdinPipe, let standardInput {
            let writer = stdinPipe.fileHandleForWriting
            defer { try? writer.close() }
            // 실행 전에 짧은 입력과 EOF를 준비. 읽지 않는 자손이 남아도 writer 대기 없음.
            guard fcntl(writer.fileDescriptor, F_SETFL, O_NONBLOCK) != -1 else {
                throw ProcessRunnerError.standardInputFailed
            }
            let written = standardInput.withUnsafeBytes {
                Darwin.write(writer.fileDescriptor, $0.baseAddress, $0.count)
            }
            guard written == standardInput.count else { throw ProcessRunnerError.standardInputFailed }
            process.standardInput = stdinPipe
        }

        // 두 pipe를 child 실행 전 background queue에서 drain 시작 — OS pipe buffer(~64KB) 초과 출력 child의 write blocking·timeout 오작동 방지, exit 후 read는 deadlock.
        let output = SubprocessOutput()
        let drained = DispatchGroup()
        let deadline = DispatchTime.now() + timeout
        let timeoutError = ProcessRunnerError.timedOut(executable: executable, timeout: timeout)
        defer {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            drained.wait()
        }
        drain(stdoutPipe.fileHandleForReading, into: output, isStdout: true, group: drained,
              deadline: deadline, timeoutError: timeoutError)
        drain(stderrPipe.fileHandleForReading, into: output, isStdout: false, group: drained,
              deadline: deadline, timeoutError: timeoutError)

        // 50ms poll loop 대신 kernel-level wait 1회 — termination handler를 `run()` 전에 등록해 즉시 종료 child와의 race 차단, `wait`는 exit 또는 deadline까지 1회 blocking.
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            exited.leave()
            throw error
        }
        try? stdinPipe?.fileHandleForReading.close()

        if exited.wait(timeout: deadline) == .timedOut {
            terminateProcessTree(rootPID: process.processIdentifier)
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw timeoutError
        }

        process.waitUntilExit()
        drained.wait()
        if let error = output.error { throw error }
        AppLog.debug(.subprocess, "exit \(process.terminationStatus)")
        return ProcessResult(exitCode: process.terminationStatus, stdout: output.stdoutString, stderr: output.stderrString)
    }

    /// 프로세스와 같은 기한까지 원문 출력 수집 — 부모 종료 뒤 자손이 pipe를 보유해도 reader 종료.
    private func drain(
        _ handle: FileHandle, into output: SubprocessOutput, isStdout: Bool, group: DispatchGroup,
        deadline: DispatchTime, timeoutError: ProcessRunnerError
    ) {
        let box = FileHandleBox(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? box.handle.close()
                group.leave()
            }
            do {
                let data = try Self.readOutput(box.handle.fileDescriptor, deadline: deadline, timeoutError: timeoutError)
                if isStdout { output.setStdout(data) } else { output.setStderr(data) }
            } catch {
                output.setError(error)
            }
        }
    }

    private static func readOutput(
        _ fileDescriptor: Int32, deadline: DispatchTime, timeoutError: ProcessRunnerError
    ) throws -> Data {
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            AppLog.error(.subprocess, "Could not configure command output (errno \(errno))")
            throw ProcessRunnerError.outputReadFailed
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let now = DispatchTime.now()
            guard now < deadline else { throw timeoutError }
            let remainingMilliseconds = (deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let polled = Darwin.poll(&descriptor, 1, Int32(max(1, min(100, remainingMilliseconds))))
            if polled == 0 { continue }
            if polled < 0, errno == EINTR { continue }
            guard polled > 0, descriptor.revents & Int16(POLLNVAL) == 0 else {
                AppLog.error(.subprocess, "Could not poll command output (errno \(errno))")
                throw ProcessRunnerError.outputReadFailed
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fileDescriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return data
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                AppLog.error(.subprocess, "Could not read command output (errno \(errno))")
                throw ProcessRunnerError.outputReadFailed
            }
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
    case standardInputUnsupported
    case standardInputFailed
    case standardInputTooLarge
    case outputReadFailed

    var errorDescription: String? {
        switch self {
        case .timedOut(let executable, let timeout):
            return "\(executable) timed out after \(Int(timeout))s."
        case .standardInputUnsupported:
            return "This process runner does not support standard input."
        case .standardInputFailed:
            return "Could not send input to the process."
        case .standardInputTooLarge:
            return "Process input exceeds 4096 bytes."
        case .outputReadFailed:
            return "Could not read output from the process."
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
    private var readError: (any Error)?

    func setStdout(_ data: Data) { lock.lock(); stdout = data; lock.unlock() }
    func setStderr(_ data: Data) { lock.lock(); stderr = data; lock.unlock() }
    func setError(_ error: any Error) { lock.lock(); if readError == nil { readError = error }; lock.unlock() }

    var error: (any Error)? { lock.lock(); defer { lock.unlock() }; return readError }
    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}
