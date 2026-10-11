import AppKit

/// 시작 시 한 번 확인하고 현지 00·15·30·45분마다 재확인. 잠자기 중 놓친 조회는 한 번으로 병합.
@MainActor
enum CodexWeeklyTimerCheckSchedule {
    enum Event: Equatable, Sendable {
        case deadline
        case wake
        case clockChanged
    }

    static func start(check: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let signal = CodexWeeklyTimerCheckSignal()
        return Task {
            await run(
                now: Date.init,
                calendar: { Calendar.current },
                wait: { await signal.wait(until: $0) },
                check: check
            )
        }
    }

    static func refreshAccounts(
        _ providerIDs: [String], using refresh: @escaping @MainActor (String) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let tasks = providerIDs.map { providerID in Task { await refresh(providerID) } }
        await withTaskCancellationHandler {
            for task in tasks { await task.value }
        } onCancel: {
            for task in tasks { task.cancel() }
        }
    }

    static func run(
        now: @escaping @MainActor () -> Date,
        calendar: @escaping @MainActor () -> Calendar,
        wait: @escaping @MainActor (Date) async -> Event?,
        check: @escaping @MainActor () async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        var nextCheckAt = nextQuarterHour(after: now(), calendar: calendar())
        await check()

        while !Task.isCancelled, let event = await wait(nextCheckAt) {
            guard !Task.isCancelled else { return }
            let current = now()
            if current < nextCheckAt {
                if event == .clockChanged {
                    nextCheckAt = nextQuarterHour(after: current, calendar: calendar())
                }
                continue
            }
            // 조회 전에 다음 경계를 예약하여 같은 15분 경계의 timeout과 wake 중복 처리 차단.
            nextCheckAt = nextQuarterHour(after: current, calendar: calendar())
            await check()
        }
    }

    private static func nextQuarterHour(after date: Date, calendar: Calendar) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: date)!
        let elapsed = date.timeIntervalSince(hour.start)
        return min(hour.end, hour.start.addingTimeInterval((floor(elapsed / 900) + 1) * 900))
    }
}

/// 시스템 깨우기와 시각 변경을 15분 경계 대기 작업 한 곳으로 전달.
@MainActor
private final class CodexWeeklyTimerCheckSignal {
    private let stream: AsyncStream<CodexWeeklyTimerCheckSchedule.Event>
    private let continuation: AsyncStream<CodexWeeklyTimerCheckSchedule.Event>.Continuation
    private let workspaceCenter: NotificationCenter
    private let systemCenter: NotificationCenter
    private nonisolated(unsafe) let wakeObserver: NSObjectProtocol
    private nonisolated(unsafe) let clockObserver: NSObjectProtocol
    private nonisolated(unsafe) let timeZoneObserver: NSObjectProtocol

    init() {
        // 시각 변경 뒤 깨우기가 도착해도 재예약 신호를 버리지 않도록 순서 보존.
        let (stream, continuation) = AsyncStream.makeStream(
            of: CodexWeeklyTimerCheckSchedule.Event.self,
            bufferingPolicy: .unbounded
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let systemCenter = NotificationCenter.default
        self.stream = stream
        self.continuation = continuation
        self.workspaceCenter = workspaceCenter
        self.systemCenter = systemCenter
        wakeObserver = workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { _ in
            continuation.yield(.wake)
        }
        clockObserver = systemCenter.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { _ in
            continuation.yield(.clockChanged)
        }
        timeZoneObserver = systemCenter.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: nil) { _ in
            continuation.yield(.clockChanged)
        }
    }

    deinit {
        workspaceCenter.removeObserver(wakeObserver)
        systemCenter.removeObserver(clockObserver)
        systemCenter.removeObserver(timeZoneObserver)
        continuation.finish()
    }

    func wait(until deadline: Date) async -> CodexWeeklyTimerCheckSchedule.Event? {
        let delay = max(0, deadline.timeIntervalSinceNow)
        let timer = Task { [continuation] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            continuation.yield(.deadline)
        }
        defer { timer.cancel() }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
