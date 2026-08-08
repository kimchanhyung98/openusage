import Foundation

/// refresh loop의 패스 사이 대기: interval sleep + enabled-provider 변경 시 조기 wake.
/// 구독은 `init`에서 동기 설치 — loop 첫 패스 전. `.bufferingNewest(1)` stream이라 대기자 없을 때의 wake도 보존,
/// burst는 한 번의 pending wake로 병합 — 패스 도중 변경 무유실.
@MainActor
final class RefreshWakeSignal {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let center: NotificationCenter
    /// nonisolated `deinit`의 observer 해제용 `nonisolated(unsafe)` — init 후 불변, `NotificationCenter`는 thread-safe 문서화.
    private nonisolated(unsafe) let observer: NSObjectProtocol

    init(
        name: Notification.Name = ProviderEnablementStore.didChangeNotification,
        center: NotificationCenter = .default
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        self.center = center
        // 동기 등록 — init 반환 후 post되는 notification 무유실. continuation은 `Sendable`이라 어느 context에서든 yield 안전.
        self.observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            continuation.yield()
        }
    }

    deinit {
        center.removeObserver(observer)
        continuation.finish()
    }

    /// wake(버퍼된 것 포함) 또는 `timeout` 중 먼저 오는 쪽에 반환; task cancel 시에도 즉시 반환.
    /// timeout과 wake race 시 패자는 buffer 잔류 — 추가 패스는 전부 cache hit로 무해. 소비자는 refresh loop 단일·순차 한정.
    func waitForWake(timeout: TimeInterval) async {
        let timer = Task { [continuation] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            continuation.yield()
        }
        defer { timer.cancel() }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
