import Darwin
import Foundation

final class ProcessTerminationController: @unchecked Sendable {
    private let lock = NSLock()
    private let forceCleanup: @Sendable () -> Void
    private var processGroupID: pid_t?
    private var terminationRequested = false
    private var terminationStarted = false
    private var completed = false
    private var terminationFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(forceCleanup: @escaping @Sendable () -> Void) {
        self.forceCleanup = forceCleanup
    }

    func prepareToLaunch() throws {
        lock.lock()
        defer { lock.unlock() }
        if terminationRequested {
            throw CancellationError()
        }
    }

    func didLaunch(processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldTerminate = terminationRequested && !terminationStarted
        if shouldTerminate {
            terminationStarted = true
        }
        lock.unlock()
        if shouldTerminate {
            startTermination(processGroupID: processGroupID)
        }
    }

    func requestTermination() {
        lock.lock()
        guard !completed else {
            lock.unlock()
            forceCleanup()
            return
        }
        terminationRequested = true
        let target = terminationStarted ? nil : processGroupID
        if target != nil {
            terminationStarted = true
        }
        lock.unlock()
        if let target {
            startTermination(processGroupID: target)
        }
    }

    func didCompleteNaturally() {
        lock.lock()
        guard !terminationStarted else {
            lock.unlock()
            return
        }
        guard let processGroupID else {
            completed = true
            lock.unlock()
            return
        }
        errno = 0
        let groupStillExists = Darwin.kill(-processGroupID, 0) == 0 || errno == EPERM
        if groupStillExists {
            terminationStarted = true
        } else {
            completed = true
            self.processGroupID = nil
        }
        lock.unlock()
        if groupStillExists {
            terminate(processGroupID: processGroupID)
        }
    }

    func waitForTermination() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !terminationStarted || terminationFinished {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func startTermination(processGroupID: pid_t) {
        terminate(processGroupID: processGroupID)
    }

    private func terminate(processGroupID: pid_t) {
        _ = Darwin.kill(-processGroupID, SIGKILL)
        forceCleanup()
        finishTermination()
    }

    private func finishTermination() {
        lock.lock()
        completed = true
        processGroupID = nil
        terminationFinished = true
        let waiters = self.waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }
}
