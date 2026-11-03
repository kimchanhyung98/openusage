import Observation

/// 수 초 뒤 스스로 사라지는 auto-clear UI notice pill의 공용 box
/// `present(_:)`는 값 설정과 `trigger` 증가로 동일 값 재표시에도 pop-in 재생 보장
/// `clear()`는 즉시 reset — store가 popover보다 오래 살므로 popover 닫힘 시 호출해 stale 재등장 방지
@MainActor
@Observable
final class TransientNotice<Value> {
    private(set) var value: Value
    /// `present`마다 증가 — `.id(trigger)` keyed view가 매번 transition을 재생하는 근거
    private(set) var trigger = 0

    // `let`은 observation 추적 대상 아님 — 가변 task에만 annotation 필요
    private let clearedValue: Value
    private let timeout: Duration
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(clearedValue: Value, timeout: Duration) {
        self.value = clearedValue
        self.clearedValue = clearedValue
        self.timeout = timeout
    }

    func present(_ newValue: Value) {
        value = newValue
        trigger += 1
        clearTask?.cancel()
        let timeout = self.timeout
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            value = clearedValue
        }
    }

    func clear() {
        value = clearedValue
        clearTask?.cancel()
        clearTask = nil
    }
}
