import Foundation

/// 호버 팝오버(사용 추세 차트, 모델 분해) 개폐 상태 코디네이터.
/// dwell 후 열림, 행과 팝오버 양쪽에서 커서 이탈 시 grace 후 닫힘.
/// `@State` 보유와 `isPresented` 바인딩을 위한 `@Observable` 참조 타입.
@MainActor
@Observable
final class HoverPopoverState {
    var isPresented = false

    /// 살아 있는 모든 코디네이터 추적 — 패널 close 경로의 일괄 dismiss용.
    /// 뷰 트리가 패널 `orderOut`에도 생존하므로 `.onDisappear`만으로는 orphan 방지 불가.
    @ObservationIgnored private static let live = NSHashTable<HoverPopoverState>.weakObjects()

    static func dismissAll() {
        for state in live.allObjects { state.dismiss() }
    }

    /// 포인터가 인라인 행/값 위에 있는지 여부 — 호버 어포던스 구동용으로 관찰 가능.
    /// `dismiss()`가 반드시 클리어 — 패널 `orderOut` 후 재오픈 시 stale `true` 방지.
    private(set) var overInline = false
    @ObservationIgnored private var overDetail = false
    /// pin 동안 커서 위치와 무관하게 팝오버 유지 (resets claim confirm/in-flight 플로우용).
    /// `dismiss()`는 pin보다 우선. `isPinned` 노출로 데이터 기반 dismissal이 claim 플로우 중 보류 가능.
    @ObservationIgnored private var pinned = false
    var isPinned: Bool { pinned }
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// 400ms 노출은 hover-tooltip dwell과 동일, 180ms grace는 행→팝오버 커서 이동 허용. 테스트 주입용.
    private let revealDelay: Duration
    private let hideGrace: Duration

    init(revealDelay: Duration = .milliseconds(400), hideGrace: Duration = .milliseconds(180)) {
        self.revealDelay = revealDelay
        self.hideGrace = hideGrace
        Self.live.add(self)
    }

    func inlineHover(_ active: Bool) {
        // `onContinuousHover`는 매 프레임 발화 — 실제 전이에만 변경해 프레임마다 알림 방지
        if overInline != active { overInline = active }
        active ? scheduleShow() : scheduleHide()
    }

    func detailHover(_ inside: Bool) {
        overDetail = inside
        if inside { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// 팝오버 pin/unpin. pin은 대기 중 hide 취소, unpin은 hover-out grace 재가동.
    func setPinned(_ active: Bool) {
        guard pinned != active else { return }
        pinned = active
        if active { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// 강제 닫기 (팝오버/대시보드 teardown) — 화면 orphan 방지.
    func dismiss() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        overInline = false
        overDetail = false
        pinned = false
        isPresented = false
    }

    private func scheduleShow() {
        hideTask?.cancel(); hideTask = nil
        guard !isPresented, showTask == nil else { return }
        let delay = revealDelay
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if overInline { isPresented = true }
            showTask = nil
        }
    }

    private func scheduleHide() {
        guard !pinned else { return }   // pin 해제 전까지 hover-out 무시
        showTask?.cancel(); showTask = nil
        hideTask?.cancel()
        let delay = hideGrace
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if !overInline, !overDetail, !pinned { isPresented = false }
            hideTask = nil
        }
    }
}
