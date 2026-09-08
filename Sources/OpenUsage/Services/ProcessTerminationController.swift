import Darwin
import Foundation

final class ProcessTerminationController: @unchecked Sendable {
    private let lock = NSLock()
    private let forceCleanup: @Sendable () -> Void
    private var processGroupID: pid_t?
    private var terminationRequested = false
    private var completed = false

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
        let shouldTerminate = terminationRequested
        if shouldTerminate { terminateLocked() }
        lock.unlock()
        if shouldTerminate { forceCleanup() }
    }

    func requestTermination() {
        lock.lock()
        terminationRequested = true
        let shouldCleanUp = completed || processGroupID != nil
        terminateLocked()
        lock.unlock()
        if shouldCleanUp { forceCleanup() }
    }

    func didCompleteNaturally() {
        requestTermination()
    }

    /// wait 실패 시 소유권을 입증할 수 없는 숫자 PID에 추가 signal 금지.
    func relinquishProcessGroup() {
        lock.lock()
        completed = true
        processGroupID = nil
        lock.unlock()
        forceCleanup()
    }

    /// leader reap 전 lock 안에서 signal과 소유권 해제를 완료해 동시 cancel의 PID 재사용 방지.
    private func terminateLocked() {
        guard !completed, let processGroupID else { return }
        if Darwin.kill(-processGroupID, SIGKILL) != 0, errno != ESRCH {
            AppLog.error(.subprocess, "Failed to terminate command process group (errno \(errno))")
        }
        self.processGroupID = nil
        completed = true
    }
}
