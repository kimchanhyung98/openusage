import Darwin
import Foundation

struct StreamingProcessRequest: Sendable, Equatable {
    var executableURL: URL
    var arguments: [String]
    var environment: [String: String]
    var currentDirectoryURL: URL?
    var timeout: TimeInterval
    var outputLimit: Int

    init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval,
        outputLimit: Int
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
}

struct StreamingProcessResult: Sendable, Equatable {
    var exitCode: Int32
    var output: String
}

protocol StreamingProcessRunning: Sendable {
    func run(
        _ request: StreamingProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult
}

extension StreamingProcessRunning {
    func run(_ request: StreamingProcessRequest) async throws -> StreamingProcessResult {
        try await run(request, onOutput: { _ in })
    }
}

struct StreamingProcessRunner: StreamingProcessRunning {
    init() {}

    func run(
        _ request: StreamingProcessRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> StreamingProcessResult {
        try Self.validate(request)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutRead = StreamingFileHandleBox(stdoutPipe.fileHandleForReading)
        let stderrRead = StreamingFileHandleBox(stderrPipe.fileHandleForReading)

        let output = StreamingProcessOutput(limit: request.outputLimit, onOutput: onOutput)
        let drains = DrainCompletion(count: 2)
        let drainStop = DrainStopSignal()
        Self.startDrain(
            stdoutRead,
            channel: .stdout,
            output: output,
            completion: drains,
            stop: drainStop
        )
        Self.startDrain(
            stderrRead,
            channel: .stderr,
            output: output,
            completion: drains,
            stop: drainStop
        )

        let exit = ProcessExitSignal()
        let termination = ProcessTerminationController {
            drainStop.requestStop()
        }

        let executableName = request.executableURL.lastPathComponent
        AppLog.debug(.subprocess, "launch \(executableName) (\(request.arguments.count) args)")

        return try await withTaskCancellationHandler {
            do {
                try termination.prepareToLaunch()
                try Task.checkCancellation()
                let pid = try Self.spawn(
                    request,
                    stdoutPipe: stdoutPipe,
                    stderrPipe: stderrPipe
                )
                termination.didLaunch(processGroupID: pid)
                Self.startWait(pid: pid, signal: exit, termination: termination)
            } catch {
                Self.closeWriteEnds(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)
                _ = await drains.wait()
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }

            Self.closeWriteEnds(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

            let outcome: ProcessWaitOutcome
            do {
                outcome = try await Self.waitForExit(
                    signal: exit,
                    drains: drains,
                    timeout: request.timeout,
                    termination: termination
                )
                try Task.checkCancellation()
            } catch {
                termination.requestTermination()
                let stopped = await exit.wait()
                _ = await drains.wait()
                AppLog.debug(.subprocess, "exit \(stopped.exitCode)")
                throw error
            }

            switch outcome {
            case .completed(let stopped, let drainFailed):
                AppLog.debug(.subprocess, "exit \(stopped.exitCode)")
                if let waitError = stopped.waitError {
                    throw StreamingProcessRunnerError.processWaitFailed(code: waitError)
                }
                if drainFailed {
                    throw StreamingProcessRunnerError.outputReadFailed
                }
                return StreamingProcessResult(exitCode: stopped.exitCode, output: output.value)
            case .timedOut:
                let stopped = await exit.wait()
                _ = await drains.wait()
                AppLog.debug(.subprocess, "exit \(stopped.exitCode)")
                throw StreamingProcessRunnerError.timedOut(timeout: request.timeout)
            }
        } onCancel: {
            termination.requestTermination()
        }
    }

    private static func validate(_ request: StreamingProcessRequest) throws {
        guard request.executableURL.isFileURL, request.executableURL.path.hasPrefix("/") else {
            throw StreamingProcessRunnerError.executableMustBeAbsolute
        }
        if let currentDirectoryURL = request.currentDirectoryURL,
           (!currentDirectoryURL.isFileURL || !currentDirectoryURL.path.hasPrefix("/")) {
            throw StreamingProcessRunnerError.currentDirectoryMustBeAbsolute
        }
        guard !request.executableURL.path.contains("\0"),
              request.arguments.allSatisfy({ !$0.contains("\0") }),
              request.currentDirectoryURL?.path.contains("\0") != true else {
            throw StreamingProcessRunnerError.invalidArgument
        }
        guard request.environment.allSatisfy({ key, value in
            !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
        }) else {
            throw StreamingProcessRunnerError.invalidEnvironment
        }
        guard request.timeout.isFinite, request.timeout > 0 else {
            throw StreamingProcessRunnerError.invalidTimeout
        }
        guard request.outputLimit >= 0 else {
            throw StreamingProcessRunnerError.invalidOutputLimit
        }
    }

    private static func waitForExit(
        signal: ProcessExitSignal,
        drains: DrainCompletion,
        timeout: TimeInterval,
        termination: ProcessTerminationController
    ) async throws -> ProcessWaitOutcome {
        try await withThrowingTaskGroup(of: ProcessWaitOutcome.self) { group in
            group.addTask {
                let stopped = await signal.wait()
                let drainFailed = await drains.wait()
                return .completed(stopped, drainFailed: drainFailed)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                return .timedOut
            }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            if case .timedOut = first {
                termination.requestTermination()
            }
            group.cancelAll()
            return first
        }
    }

    private static func spawn(
        _ request: StreamingProcessRequest,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        try requireSpawnSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor

        try "/dev/null".withCString { path in
            try requireSpawnSuccess(
                posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, path, O_RDONLY, 0)
            )
        }
        try requireSpawnSuccess(posix_spawn_file_actions_adddup2(&fileActions, stdoutWrite, STDOUT_FILENO))
        try requireSpawnSuccess(posix_spawn_file_actions_adddup2(&fileActions, stderrWrite, STDERR_FILENO))
        for descriptor in [stdoutRead, stdoutWrite, stderrRead, stderrWrite]
            where descriptor > STDERR_FILENO
        {
            try requireSpawnSuccess(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }
        if let directory = request.currentDirectoryURL {
            try directory.path.withCString { path in
                try requireSpawnSuccess(posix_spawn_file_actions_addchdir_np(&fileActions, path))
            }
        }

        var attributes: posix_spawnattr_t?
        try requireSpawnSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        let flags = Int16(POSIX_SPAWN_SETPGROUP) | Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)
        try requireSpawnSuccess(posix_spawnattr_setflags(&attributes, flags))
        try requireSpawnSuccess(posix_spawnattr_setpgroup(&attributes, 0))

        let path = request.executableURL.path
        let argv = [path] + request.arguments
        let environment = request.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid = pid_t(0)
        let spawnStatus = try path.withCString { executable in
            try withCStringArray(argv) { argvPointer in
                try withCStringArray(environment) { environmentPointer in
                    posix_spawn(
                        &pid,
                        executable,
                        &fileActions,
                        &attributes,
                        argvPointer,
                        environmentPointer
                    )
                }
            }
        }
        try requireSpawnSuccess(spawnStatus)
        return pid
    }

    private static func requireSpawnSuccess(_ status: Int32) throws {
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(status))
        }
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var pointers = strings.map { strdup($0) }
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        pointers.append(nil)
        return try pointers.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private static func startWait(
        pid: pid_t,
        signal: ProcessExitSignal,
        termination: ProcessTerminationController
    ) {
        DispatchQueue.global(qos: .utility).async {
            var info = siginfo_t()
            var observed: Int32
            repeat {
                observed = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            } while observed == -1 && errno == EINTR
            guard observed == 0 else {
                let code = errno
                termination.relinquishProcessGroup()
                AppLog.error(.subprocess, "Failed to observe command exit (errno \(code))")
                signal.finish(ProcessExit(waitStatus: 1 << 8, waitError: code))
                return
            }
            // WNOWAIT로 leader PID를 유지한 채 원래 group 정리 후 reap.
            termination.didCompleteNaturally()
            var status = Int32(0)
            var result: pid_t
            repeat {
                result = waitpid(pid, &status, 0)
            } while result == -1 && errno == EINTR
            let waitError = result == pid ? nil : errno
            if let waitError {
                AppLog.error(.subprocess, "Failed to reap command process (errno \(waitError))")
            }
            signal.finish(ProcessExit(waitStatus: result == pid ? status : 1 << 8, waitError: waitError))
        }
    }

    private static func startDrain(
        _ handle: StreamingFileHandleBox,
        channel: ProcessOutputChannel,
        output: StreamingProcessOutput,
        completion: DrainCompletion,
        stop: DrainStopSignal
    ) {
        let fileDescriptor = handle.handle.fileDescriptor
        let flags = fcntl(fileDescriptor, F_GETFL)
        guard flags >= 0, fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            output.finish(channel: channel)
            try? handle.handle.close()
            completion.finish(failed: true)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            var failed = false
            var reachedEnd = false
            var buffer = [UInt8](repeating: 0, count: 4_096)
            var finalDrainBytes = 65_536
            while !reachedEnd {
                var descriptor = pollfd(
                    fd: fileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
                let pollResult = Darwin.poll(&descriptor, 1, stop.isStopped ? 0 : 100)
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    break
                }
                if pollResult == 0 {
                    if stop.isStopped { break }
                    continue
                }
                if descriptor.revents & Int16(POLLNVAL) != 0 {
                    failed = true
                    break
                }

                while !reachedEnd {
                    let isFinalRead = stop.isStopped
                    // 이미 buffered된 끝부분은 보존하되 detached writer가 무한히 붙잡지 않도록 제한.
                    if isFinalRead, finalDrainBytes <= 0 {
                        reachedEnd = true
                        break
                    }
                    let byteCount = buffer.withUnsafeMutableBytes { bytes in
                        Darwin.read(fileDescriptor, bytes.baseAddress, bytes.count)
                    }
                    if byteCount > 0 {
                        output.append(Data(buffer.prefix(byteCount)), channel: channel)
                        if isFinalRead { finalDrainBytes -= byteCount }
                    } else if byteCount == 0 {
                        reachedEnd = true
                        break
                    } else if errno == EINTR {
                        continue
                    } else if errno == EAGAIN || errno == EWOULDBLOCK {
                        break
                    } else {
                        failed = true
                        reachedEnd = true
                        break
                    }
                }
            }
            output.finish(channel: channel)
            try? handle.handle.close()
            completion.finish(failed: failed)
        }
    }

    private static func closeWriteEnds(stdoutPipe: Pipe, stderrPipe: Pipe) {
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
    }
}
