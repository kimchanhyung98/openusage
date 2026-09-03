import Foundation
import XCTest
@testable import OpenUsage

@MainActor
final class CodexResetWatchCoordinatorTests: XCTestCase {
    func testCadenceIsThreeUsageRefreshIntervals() {
        XCTAssertEqual(CodexResetWatchCoordinator.refreshInterval, 900)
        XCTAssertEqual(
            CodexResetWatchCoordinator.refreshInterval,
            RefreshSetting.interval * 3
        )
    }

    func testInactiveCoordinatorDoesNotLoad() async {
        let loader = ResetWatchLoadProbe(result: nil)
        var published: [CodexResetWatch?] = []
        let coordinator = CodexResetWatchCoordinator(
            load: { await loader.load() },
            publish: { published.append($0) }
        )

        try? await Task.sleep(for: .milliseconds(10))

        let loadCount = await loader.count()
        XCTAssertEqual(loadCount, 0)
        XCTAssertTrue(published.isEmpty)
        withExtendedLifetime(coordinator) {}
    }

    func testActivationLoadsImmediatelyThenUsesIndependentCadence() async {
        let watch = CodexResetWatch(
            chancePercent: 75,
            deadline: Date(timeIntervalSince1970: 1_800_003_600)
        )
        let loader = ResetWatchLoadProbe(results: [watch, nil])
        let waiter = ResetWatchWaitProbe()
        var published: [CodexResetWatch?] = []
        let coordinator = CodexResetWatchCoordinator(
            load: { await loader.load() },
            publish: { published.append($0) },
            wait: { await waiter.wait($0) }
        )

        coordinator.setActive(true)
        let firstLoadCompleted = await eventually {
            let loadCount = await loader.count()
            let waitCount = await waiter.count()
            return loadCount == 1 && waitCount == 1
        }
        let firstDuration = await waiter.firstDuration()
        XCTAssertTrue(firstLoadCompleted)
        XCTAssertEqual(firstDuration, .seconds(900))
        XCTAssertEqual(published, [watch])

        coordinator.setActive(true)
        try? await Task.sleep(for: .milliseconds(10))
        let repeatedActivationLoadCount = await loader.count()
        XCTAssertEqual(repeatedActivationLoadCount, 1, "repeated activation must not start another task")

        await waiter.resumeNext(returning: true)
        let secondLoadCompleted = await eventually {
            let loadCount = await loader.count()
            let waitCount = await waiter.count()
            return loadCount == 2 && waitCount == 2
        }
        XCTAssertTrue(secondLoadCompleted)
        XCTAssertEqual(published, [watch, nil], "a later empty response must clear the overlay")

        coordinator.setActive(false)
        await waiter.resumeAll(returning: false)
        XCTAssertEqual(published.count, 3)
        XCTAssertNil(published.last!)
    }

    func testDeactivationSuppressesLateLoadAndStopsFutureWork() async {
        let watch = CodexResetWatch(
            chancePercent: 80,
            deadline: Date(timeIntervalSince1970: 1_800_003_600)
        )
        let loader = BlockingResetWatchLoadProbe()
        var published: [CodexResetWatch?] = []
        let coordinator = CodexResetWatchCoordinator(
            load: { await loader.load() },
            publish: { published.append($0) }
        )

        coordinator.setActive(true)
        coordinator.setActive(true)
        let loadStarted = await eventually { await loader.count() == 1 }
        XCTAssertTrue(loadStarted)

        coordinator.setActive(false)
        await loader.resumeNext(returning: watch)
        try? await Task.sleep(for: .milliseconds(10))

        let loadCount = await loader.count()
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(published.count, 1)
        XCTAssertNil(published[0])
    }

    func testReactivationCannotBeOverwrittenByAnOlderLoad() async {
        let older = CodexResetWatch(
            chancePercent: 60,
            deadline: Date(timeIntervalSince1970: 1_800_003_600)
        )
        let newer = CodexResetWatch(
            chancePercent: 80,
            deadline: Date(timeIntervalSince1970: 1_800_007_200)
        )
        let loader = BlockingResetWatchLoadProbe()
        var published: [CodexResetWatch?] = []
        let coordinator = CodexResetWatchCoordinator(
            load: { await loader.load() },
            publish: { published.append($0) }
        )

        coordinator.setActive(true)
        let olderStarted = await eventually { await loader.count() == 1 }
        XCTAssertTrue(olderStarted)

        coordinator.setActive(false)
        coordinator.setActive(true)
        let newerStarted = await eventually { await loader.count() == 2 }
        XCTAssertTrue(newerStarted)

        await loader.resume(at: 1, returning: newer)
        let newerPublished = await eventually { published == [nil, newer] }
        XCTAssertTrue(newerPublished)

        await loader.resume(at: 0, returning: older)
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(published, [nil, newer])

        coordinator.setActive(false)
    }

    private func eventually(
        _ condition: @escaping @MainActor @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }
}

private actor ResetWatchLoadProbe {
    private var results: [CodexResetWatch?]
    private var loadCount = 0

    init(result: CodexResetWatch?) {
        self.results = [result]
    }

    init(results: [CodexResetWatch?]) {
        self.results = results
    }

    func load() -> CodexResetWatch? {
        loadCount += 1
        guard results.count > 1 else { return results.first ?? nil }
        return results.removeFirst()
    }

    func count() -> Int {
        loadCount
    }
}

private actor BlockingResetWatchLoadProbe {
    private var loadCount = 0
    private var continuations: [CheckedContinuation<CodexResetWatch?, Never>] = []

    func load() async -> CodexResetWatch? {
        loadCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func count() -> Int {
        loadCount
    }

    func resumeNext(returning watch: CodexResetWatch?) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: watch)
    }

    func resume(at index: Int, returning watch: CodexResetWatch?) {
        guard continuations.indices.contains(index) else { return }
        continuations.remove(at: index).resume(returning: watch)
    }
}

private actor ResetWatchWaitProbe {
    private var durations: [Duration] = []
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    func wait(_ duration: Duration) async -> Bool {
        durations.append(duration)
        return await withCheckedContinuation { continuations.append($0) }
    }

    func count() -> Int {
        durations.count
    }

    func firstDuration() -> Duration? {
        durations.first
    }

    func resumeNext(returning value: Bool) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: value)
    }

    func resumeAll(returning value: Bool) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}
