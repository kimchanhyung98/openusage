import AppKit
import Observation

/// 메뉴 바 strip 렌더 loop (`StatusItemController`에서 분리): pinned-metric strip 렌더 + 참조 값 변경 시 재렌더.
/// `withObservationTracking`의 `onChange`는 one-shot이라 렌더마다 re-arm.
/// 변경 후 짧은 대기로 snapshot 쓰기 burst를 최신 값 1회 렌더로 병합.
@MainActor
final class StatusItemImageUpdater {
    private let container: AppContainer
    private let apply: (NSImage) -> Void

    /// - Parameter apply: 렌더된 image를 status-item button에 적용.
    init(container: AppContainer, apply: @escaping (NSImage) -> Void) {
        self.container = container
        self.apply = apply
    }

    /// 즉시 렌더 + 다음 observable 변경에 re-arm.
    func update() {
        let image = withObservationTracking {
            renderButtonImage()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDelayedUpdate()
            }
        }
        apply(image)
    }

    /// observation callback은 `update()`의 re-arm까지 1회만 발화. 대기로 직후 쓰기를 먼저 반영.
    private func scheduleDelayedUpdate() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            self?.update()
        }
    }

    /// 선택 style의 pinned-metric strip, pin 없으면 앱 icon.
    private func renderButtonImage() -> NSImage {
        // 화면 공유 중 strip을 wordmark로 대체 — 사용량 수치 비노출. observation closure 내부에서 읽어 캡처 상태 변경에도 re-arm.
        if container.privacy.concealUsage {
            return MenuBarStripRenderer.privacyImage
                ?? MenuBarIcon.image
                ?? MenuBarStripRenderer.fallbackIcon
        }
        let content = MenuBarContentBuilder.build(
            groups: container.layout.pinnedGroups,
            data: { container.dataStore.data(for: $0) },
            title: { container.displayName(for: $0) }
        )
        return MenuBarStripRenderer.image(for: content, style: container.layout.menuBarStyle)
            ?? MenuBarIcon.image
            ?? MenuBarStripRenderer.fallbackIcon
    }
}
