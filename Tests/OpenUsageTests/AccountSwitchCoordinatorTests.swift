import XCTest
@testable import OpenUsage

@MainActor
final class AccountSwitchCoordinatorTests: XCTestCase {
    func testRejectsOtherRequestsUntilRefreshAndOperationCompletion() async throws {
        let coordinator = AccountSwitchCoordinator()
        let priorRefresh = Gate()
        let operation = Gate()
        let followingRefresh = Gate()
        defer { priorRefresh.open(); operation.open(); followingRefresh.open() }
        let priorStarted = expectation(description: "Waiting for existing refreshes")
        let operationStarted = expectation(description: "Account operation started")
        let followingStarted = expectation(description: "Waiting for following refreshes")
        var waitCount = 0
        var operationCount = 0
        let task = try XCTUnwrap(coordinator.start(
            profileID: "account-A",
            waitForRefreshes: {
                waitCount += 1
                if waitCount == 1 {
                    priorStarted.fulfill()
                    await priorRefresh.wait()
                } else {
                    followingStarted.fulfill()
                    await followingRefresh.wait()
                }
            },
            operation: {
                operationCount += 1
                operationStarted.fulfill()
                await operation.wait()
            },
            onFailure: { XCTFail("Unexpected failure: \($0)") }
        ))

        XCTAssertTrue(coordinator.isSwitching, "The request must reserve the shared state before returning")
        XCTAssertEqual(coordinator.profileID, "account-A")
        assertRejected(coordinator, profileID: "account-B")
        await fulfillment(of: [priorStarted], timeout: 2)
        XCTAssertEqual(operationCount, 0)
        assertRejected(coordinator, profileID: "account-C")

        priorRefresh.open()
        await fulfillment(of: [operationStarted], timeout: 2)
        XCTAssertEqual(operationCount, 1)
        assertRejected(coordinator, profileID: "account-D")
        operation.open()
        await fulfillment(of: [followingStarted], timeout: 2)
        XCTAssertEqual(coordinator.profileID, "account-A")
        assertRejected(coordinator, profileID: "account-E")

        followingRefresh.open()
        await task.value
        XCTAssertEqual(waitCount, 2)
        XCTAssertEqual(operationCount, 1)
        try await assertAvailableForNextAccount(coordinator)
    }

    func testFailureKeepsReservationUntilFollowingRefreshesFinish() async throws {
        let coordinator = AccountSwitchCoordinator()
        let followingRefresh = Gate()
        defer { followingRefresh.open() }
        let followingStarted = expectation(description: "Waiting after account failure")
        var waitCount = 0
        var failureCount = 0
        let task = try XCTUnwrap(coordinator.start(
            profileID: "account-A",
            waitForRefreshes: {
                waitCount += 1
                if waitCount == 2 {
                    followingStarted.fulfill()
                    await followingRefresh.wait()
                }
            },
            operation: { throw SwitchFailure.failed },
            onFailure: { error in
                XCTAssertEqual(error as? SwitchFailure, .failed)
                XCTAssertEqual(coordinator.profileID, "account-A")
                failureCount += 1
            }
        ))

        await fulfillment(of: [followingStarted], timeout: 2)
        XCTAssertEqual(failureCount, 1)
        assertRejected(coordinator, profileID: "account-B")
        followingRefresh.open()
        await task.value
        XCTAssertEqual(waitCount, 2)
        XCTAssertEqual(failureCount, 1)
        try await assertAvailableForNextAccount(coordinator)
    }

    func testCancellationBeforeOperationWaitsForBothRefreshBarriers() async throws {
        let coordinator = AccountSwitchCoordinator()
        let priorRefresh = Gate()
        let followingRefresh = Gate()
        defer { priorRefresh.open(); followingRefresh.open() }
        let priorStarted = expectation(description: "Waiting before cancellation")
        let followingStarted = expectation(description: "Waiting after cancellation")
        var waitCount = 0
        var operationCount = 0
        var failureCount = 0
        let task = try XCTUnwrap(coordinator.start(
            profileID: "account-A",
            waitForRefreshes: {
                waitCount += 1
                if waitCount == 1 {
                    priorStarted.fulfill()
                    await priorRefresh.wait()
                } else {
                    followingStarted.fulfill()
                    await followingRefresh.wait()
                }
            },
            operation: { operationCount += 1 },
            onFailure: { error in
                XCTAssertTrue(error is CancellationError)
                failureCount += 1
            }
        ))

        await fulfillment(of: [priorStarted], timeout: 2)
        task.cancel()
        assertRejected(coordinator, profileID: "account-B")
        XCTAssertEqual(failureCount, 0, "Cancellation must not bypass the existing refresh barrier")
        priorRefresh.open()
        await fulfillment(of: [followingStarted], timeout: 2)
        XCTAssertEqual(operationCount, 0, "A cancelled request must not change the account")
        XCTAssertEqual(failureCount, 1)
        assertRejected(coordinator, profileID: "account-C")

        followingRefresh.open()
        await task.value
        XCTAssertEqual(waitCount, 2)
        try await assertAvailableForNextAccount(coordinator)
    }

    func testCancellationDuringOperationKeepsReservationUntilWorkAndRefreshesFinish() async throws {
        let coordinator = AccountSwitchCoordinator()
        let operation = Gate()
        let followingRefresh = Gate()
        defer { operation.open(); followingRefresh.open() }
        let operationStarted = expectation(description: "Account operation started")
        let followingStarted = expectation(description: "Waiting after cancelled operation")
        var waitCount = 0
        var failureCount = 0
        let task = try XCTUnwrap(coordinator.start(
            profileID: "account-A",
            waitForRefreshes: {
                waitCount += 1
                if waitCount == 2 {
                    followingStarted.fulfill()
                    await followingRefresh.wait()
                }
            },
            operation: {
                operationStarted.fulfill()
                await operation.wait()
                try Task.checkCancellation()
            },
            onFailure: { error in
                XCTAssertTrue(error is CancellationError)
                failureCount += 1
            }
        ))

        await fulfillment(of: [operationStarted], timeout: 2)
        task.cancel()
        XCTAssertEqual(failureCount, 0)
        assertRejected(coordinator, profileID: "account-B")
        operation.open()
        await fulfillment(of: [followingStarted], timeout: 2)
        XCTAssertEqual(failureCount, 1)
        assertRejected(coordinator, profileID: "account-C")

        followingRefresh.open()
        await task.value
        XCTAssertEqual(waitCount, 2)
        try await assertAvailableForNextAccount(coordinator)
    }

    func testRealStoreKeepsSwitchReservedUntilCancelledProviderWorkActuallyFinishes() async throws {
        let suite = "OpenUsageTests.AccountSwitchCoordinator.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let runtime = Runtime()
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults, providerRefreshTimeout: 60,
            providerIdentityKeys: ["codex": "account-A"]
        )
        let coordinator = AccountSwitchCoordinator()
        let priorRefresh = Gate()
        let followingRefresh = Gate()
        defer { priorRefresh.open(); followingRefresh.open() }
        let priorStarted = expectation(description: "Existing provider work started")
        let followingStarted = expectation(description: "Selected-account provider work started")
        let priorWaitStarted = expectation(description: "Coordinator waits for existing provider work")
        let followingWaitStarted = expectation(description: "Coordinator waits for remaining provider work")
        runtime.beforeRefresh = { attempt in
            if attempt == 1 {
                priorStarted.fulfill()
                await priorRefresh.wait()
            } else {
                followingStarted.fulfill()
                await followingRefresh.wait()
            }
        }
        let priorTask = Task { await store.refresh(providerID: "codex", force: true) }
        await fulfillment(of: [priorStarted], timeout: 2)
        priorTask.cancel()
        let priorOutcome = await priorTask.value
        XCTAssertEqual(priorOutcome, .skipped)
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
        XCTAssertEqual(runtime.completedCount, 0)
        var waitCount = 0
        var operationCount = 0
        let task = try XCTUnwrap(coordinator.start(
            profileID: "account-B",
            waitForRefreshes: {
                waitCount += 1
                if waitCount == 1 { priorWaitStarted.fulfill() }
                else { followingWaitStarted.fulfill() }
                await store.waitForAccountRefreshes()
            },
            operation: {
                operationCount += 1
                XCTAssertEqual(runtime.completedCount, 1)
                let refresh = Task {
                    await store.refresh(providerID: "codex", force: true, trigger: .accountChange)
                }
                await self.fulfillment(of: [followingStarted], timeout: 2)
                refresh.cancel()
                let outcome = await refresh.value
                XCTAssertEqual(outcome, .skipped)
            },
            onFailure: { XCTFail("Unexpected failure: \($0)") }
        ))

        await fulfillment(of: [priorWaitStarted], timeout: 2)
        XCTAssertEqual(operationCount, 0)
        assertRejected(coordinator, profileID: "account-C")
        priorRefresh.open()
        await fulfillment(of: [followingWaitStarted], timeout: 2)
        XCTAssertEqual(operationCount, 1)
        XCTAssertEqual(runtime.refreshCount, 2)
        XCTAssertEqual(runtime.completedCount, 1)
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
        XCTAssertNil(store.localSnapshots["codex"])
        XCTAssertEqual(coordinator.profileID, "account-B")
        task.cancel()
        assertRejected(coordinator, profileID: "account-D")

        followingRefresh.open()
        await task.value
        XCTAssertEqual(runtime.completedCount, 2)
        XCTAssertEqual(runtime.refreshCount, 2, "Rejected requests must not become queued refreshes")
        XCTAssertNil(store.localSnapshots["codex"], "Cancelled work must not publish a late account snapshot")
        try await assertAvailableForNextAccount(coordinator)
    }

    private func assertRejected(
        _ coordinator: AccountSwitchCoordinator, profileID: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let task = coordinator.start(
            profileID: profileID,
            waitForRefreshes: { XCTFail("Rejected request entered refresh wait", file: file, line: line) },
            operation: { XCTFail("Rejected request changed the account", file: file, line: line) },
            onFailure: { _ in XCTFail("Rejected request reported a failure", file: file, line: line) }
        )
        XCTAssertNil(task, "Busy requests must be rejected without queuing", file: file, line: line)
        XCTAssertTrue(coordinator.isSwitching, file: file, line: line)
    }

    private func assertAvailableForNextAccount(_ coordinator: AccountSwitchCoordinator) async throws {
        XCTAssertFalse(coordinator.isSwitching)
        XCTAssertNil(coordinator.profileID)
        var operationCount = 0
        let next = try XCTUnwrap(coordinator.start(
            profileID: "next-account", waitForRefreshes: {},
            operation: { operationCount += 1 },
            onFailure: { XCTFail("Unexpected next-account failure: \($0)") }
        ))
        XCTAssertEqual(coordinator.profileID, "next-account")
        await next.value
        XCTAssertEqual(operationCount, 1)
        XCTAssertFalse(coordinator.isSwitching)
        XCTAssertNil(coordinator.profileID)
    }

    private enum SwitchFailure: Error { case failed }

    private final class Runtime: ProviderRuntime {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let widgetDescriptors: [WidgetDescriptor] = []
        var refreshCount = 0
        var completedCount = 0
        var beforeRefresh: @MainActor (Int) async -> Void = { _ in }

        func hasLocalCredentials() async -> Bool { true }
        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            await beforeRefresh(refreshCount)
            completedCount += 1
            return ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
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
