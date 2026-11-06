import Foundation

/// 실제 작업 하나만 실행하는 FIFO 큐. 대기 취소와 실행 종료를 분리.
@MainActor
final class BackgroundWorkQueue {
    nonisolated static let shared = BackgroundWorkQueue()
    struct Ticket: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    private struct Job {
        let ticket: Ticket
        let name: String
        let enqueuedAt: TimeInterval
        var startedAt: TimeInterval?
        var continuation: CheckedContinuation<Ticket?, Never>?
    }

    private var nextID: UInt64 = 0
    private var active: Job?
    private var waiting: [Job] = []
    var pendingCount: Int { waiting.count }

    nonisolated init() {}

    func acquire(_ name: String) async -> Ticket? {
        guard !Task.isCancelled else { return nil }
        nextID &+= 1
        let ticket = Ticket(id: nextID)
        let job = Job(ticket: ticket, name: name, enqueuedAt: ProcessInfo.processInfo.systemUptime)
        if active == nil {
            start(job)
            return ticket
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                var queued = job
                queued.continuation = continuation
                waiting.append(queued)
                AppLog.debug(.refresh, "queue waiting #\(ticket.id) \(name) (pending=\(waiting.count))")
            }
        } onCancel: {
            Task { @MainActor in self.cancel(ticket) }
        }
    }

    /// 시간 초과로 호출자가 먼저 돌아가더라도 실제 작업의 종료 지점에서만 호출.
    func finish(_ ticket: Ticket) {
        guard let job = active, job.ticket == ticket else { return }
        let elapsed = milliseconds(since: job.startedAt ?? job.enqueuedAt)
        AppLog.info(.refresh, "queue end #\(ticket.id) \(job.name) (run=\(elapsed)ms, pending=\(waiting.count))")
        active = nil
        if !waiting.isEmpty { start(waiting.removeFirst()) }
    }

    func run<T>(_ name: String, operation: @MainActor () async throws -> T) async rethrows -> T? {
        guard let ticket = await acquire(name) else { return nil }
        defer { finish(ticket) }
        guard !Task.isCancelled else { return nil }
        return try await operation()
    }

    private func start(_ job: Job) {
        var job = job
        job.startedAt = ProcessInfo.processInfo.systemUptime
        let continuation = job.continuation
        job.continuation = nil
        active = job
        AppLog.info(
            .refresh,
            "queue start #\(job.ticket.id) \(job.name) (wait=\(milliseconds(since: job.enqueuedAt))ms, pending=\(waiting.count))"
        )
        continuation?.resume(returning: job.ticket)
    }

    private func cancel(_ ticket: Ticket) {
        guard let index = waiting.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiting.remove(at: index).continuation?.resume(returning: nil)
        AppLog.debug(.refresh, "queue cancelled #\(ticket.id) (pending=\(waiting.count))")
    }

    private func milliseconds(since start: TimeInterval) -> Int {
        max(0, Int((ProcessInfo.processInfo.systemUptime - start) * 1000))
    }
}
