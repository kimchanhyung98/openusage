import XCTest
@testable import OpenUsage

@MainActor
final class ProviderRefreshDeadlineTests: XCTestCase {
    func testSuccessfulWorkCancelsItsTimer() async {
        let timerStarted = expectation(description: "Timer started")
        let timerCancelled = expectation(description: "Timer cancelled")
        let gate = Gate()
        let snapshot = ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
        let task = Task {
            await ProviderRefreshDeadline.run(timeout: .seconds(120), sleep: { _ in
                timerStarted.fulfill()
                do { try await Task.sleep(for: .seconds(60)) }
                catch { timerCancelled.fulfill(); throw error }
            }) {
                await gate.wait()
                return snapshot
            }
        }
        await fulfillment(of: [timerStarted], timeout: 2)
        gate.open()
        guard case .snapshot(let result) = await task.value else { return XCTFail("Expected snapshot") }
        XCTAssertEqual(result, snapshot)
        await fulfillment(of: [timerCancelled], timeout: 2)
    }

    func testTimeoutReturnsBeforeNoncooperativeWorkAndLateCompletionIsIgnored() async {
        let started = expectation(description: "Work started")
        let finished = expectation(description: "Late work finished")
        let cancelled = expectation(description: "Work cancellation requested")
        let timerGate = Gate()
        let workGate = Gate()
        let task = Task {
            await ProviderRefreshDeadline.run(timeout: .seconds(120), sleep: { _ in await timerGate.wait() }) {
                await withTaskCancellationHandler {
                    started.fulfill()
                    await workGate.wait()
                    finished.fulfill()
                    return ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
                } onCancel: { cancelled.fulfill() }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        timerGate.open()
        guard case .timedOut = await task.value else { return XCTFail("Expected timeout") }
        await fulfillment(of: [cancelled], timeout: 2)
        workGate.open()
        await fulfillment(of: [finished], timeout: 2)
    }

    func testCancellationBeforeContinuationRegistrationDoesNotStartWork() async {
        var started = false
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ProviderRefreshDeadline.run(timeout: .seconds(120)) {
                started = true
                return ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
            }
        }
        guard case .cancelled = await task.value else { return XCTFail("Expected cancellation") }
        XCTAssertFalse(started)
    }

    func testCancellationAndDeadlineRaceResumesOnce() async {
        for _ in 0..<20 {
            let started = expectation(description: "Work started")
            let finished = expectation(description: "Work finished")
            let timerGate = Gate()
            let workGate = Gate()
            let task = Task {
                await ProviderRefreshDeadline.run(timeout: .seconds(120), sleep: { _ in await timerGate.wait() }) {
                    started.fulfill()
                    await workGate.wait()
                    finished.fulfill()
                    return ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
                }
            }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            timerGate.open()
            switch await task.value {
            case .cancelled, .timedOut: break
            case .snapshot: XCTFail("Cancelled work must not win")
            }
            workGate.open()
            await fulfillment(of: [finished], timeout: 2)
        }
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }
}
