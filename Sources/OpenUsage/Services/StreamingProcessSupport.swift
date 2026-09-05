import Foundation

enum StreamingProcessRunnerError: Error, LocalizedError, Equatable {
    case executableMustBeAbsolute
    case currentDirectoryMustBeAbsolute
    case invalidTimeout
    case invalidOutputLimit
    case invalidArgument
    case invalidEnvironment
    case outputReadFailed
    case processWaitFailed(code: Int32)
    case timedOut(timeout: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .executableMustBeAbsolute:
            "The executable path must be absolute."
        case .currentDirectoryMustBeAbsolute:
            "The working-directory path must be absolute."
        case .invalidTimeout:
            "The command timeout must be finite and greater than zero."
        case .invalidOutputLimit:
            "The command output limit cannot be negative."
        case .invalidArgument:
            "Command arguments cannot contain null bytes."
        case .invalidEnvironment:
            "The command environment is malformed."
        case .outputReadFailed:
            "The command output could not be read."
        case .processWaitFailed:
            "The command exit could not be confirmed. Please try again."
        case .timedOut(let timeout):
            "The command timed out after \(timeout.formatted()) seconds."
        }
    }
}

struct ProcessExit: Sendable {
    var waitStatus: Int32
    var waitError: Int32? = nil

    var exitCode: Int32 {
        let signal = waitStatus & 0x7F
        return signal == 0 ? (waitStatus >> 8) & 0xFF : 128 + signal
    }
}

enum ProcessWaitOutcome: Sendable {
    case completed(ProcessExit, drainFailed: Bool)
    case timedOut
}

final class ProcessExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ProcessExit?
    private var waiters: [CheckedContinuation<ProcessExit, Never>] = []

    func finish(_ result: ProcessExit) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func wait() async -> ProcessExit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class DrainCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var failed = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    init(count: Int) {
        self.remaining = count
    }

    func finish(failed: Bool) {
        lock.lock()
        self.failed = self.failed || failed
        remaining -= 1
        guard remaining == 0 else {
            lock.unlock()
            return
        }
        let result = self.failed
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if remaining == 0 {
                let result = failed
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

final class DrainStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func requestStop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

final class StreamingFileHandleBox: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}
