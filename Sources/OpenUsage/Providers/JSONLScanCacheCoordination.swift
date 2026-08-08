import Foundation

/// 모든 provider/home identity가 공유하는 scanner 전역 I/O budget — 없으면 identity당 8개 parse task가 multi-account launch에서 수십 개 동시 read로 불어남.
actor JSONLParsePermitPool {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Bool, Never>
    }

    private var available: Int
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.available = limit
    }

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            available += 1
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

enum PersistentJSONLScanCaches {
    /// one-shot CLI는 debounce를 넘길 run loop이 없어 종료 전 모든 로컬 로그 parser를 명시적으로 drain. pending 없는 scanner는 즉시 반환.
    static func flushPendingWrites() async {
        await ClaudeLogUsageScanner.flushPersistentCacheWrites()
        await CodexLogUsageScanner.flushPersistentCacheWrites()
        await PiUsageScanner.flushPersistentCacheWrites()
    }
}
