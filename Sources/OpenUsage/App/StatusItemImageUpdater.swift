import AppKit
import Observation

/// 메뉴 바 strip 렌더 loop (`StatusItemController`에서 분리): pinned-metric strip 렌더 + 참조 값 변경 시 재렌더.
/// `withObservationTracking`의 `onChange`는 one-shot이라 렌더마다 re-arm.
/// capture 시작만 즉시 적용(지연 시 수치 노출), 나머지 변경은 짧게 병합.
@MainActor
final class StatusItemImageUpdater {
    private let privacy: MenuBarPrivacyStore
    private let renderButtonImage: @MainActor (_ concealed: Bool) -> NSImage
    private let delay: @MainActor () async -> Void
    private let apply: (NSImage) -> Void
    private var delayedUpdateTask: Task<Void, Never>?

    /// - Parameter apply: 렌더된 image를 status-item button에 적용.
    convenience init(container: AppContainer, apply: @escaping (NSImage) -> Void) {
        self.init(
            privacy: container.privacy,
            renderButtonImage: { concealed in
                Self.renderButtonImage(container: container, concealed: concealed)
            },
            delay: { try? await Task.sleep(for: .milliseconds(50)) },
            apply: apply
        )
    }

    init(
        privacy: MenuBarPrivacyStore,
        renderButtonImage: @escaping @MainActor (_ concealed: Bool) -> NSImage,
        delay: @escaping @MainActor () async -> Void,
        apply: @escaping (NSImage) -> Void
    ) {
        self.privacy = privacy
        self.renderButtonImage = renderButtonImage
        self.delay = delay
        self.apply = apply
        privacy.setConcealUsageObserver { [weak self] concealed in
            self?.privacyDidChange(to: concealed)
        }
    }

    /// 즉시 렌더 + 다음 observable 변경에 re-arm.
    func update() {
        applyImmediately(concealed: privacy.concealUsage)
    }

    private func privacyDidChange(to concealed: Bool) {
        applyImmediately(concealed: concealed)
    }

    private func applyImmediately(concealed: Bool) {
        delayedUpdateTask?.cancel()
        delayedUpdateTask = nil
        apply(observeAndRender(concealed: concealed))
    }

    private func observeAndRender(concealed: Bool? = nil) -> NSImage {
        let image = withObservationTracking {
            let currentConcealment = privacy.concealUsage
            return renderButtonImage(concealed ?? currentConcealment)
        } onChange: { [weak self] in
            // 일반 UI write는 저장 전 callback에서 렌더하지 않고 delay 뒤 최신 상태를 한 번 렌더.
            MainActor.assumeIsolated {
                self?.scheduleDelayedUpdate()
            }
        }
        return image
    }

    private func scheduleDelayedUpdate() {
        delayedUpdateTask?.cancel()
        let delay = delay
        delayedUpdateTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await delay()
            guard !Task.isCancelled, let self else { return }
            let image = self.observeAndRender()
            self.apply(image)
            self.delayedUpdateTask = nil
        }
    }

    /// 선택 style의 pinned-metric strip, pin 없으면 앱 icon.
    private static func renderButtonImage(container: AppContainer, concealed: Bool) -> NSImage {
        // 화면 공유 중 strip을 wordmark로 대체 — post-mutation edge의 명시 값 사용.
        if concealed {
            return MenuBarStripRenderer.privacyImage
                ?? MenuBarIcon.image
                ?? MenuBarStripRenderer.fallbackIcon
        }
        let content = MenuBarContentBuilder.build(
            groups: stripGroups(container: container),
            data: { container.dataStore.data(for: $0) },
            title: { container.displayName(for: $0) }
        )
        return MenuBarStripRenderer.image(for: content, style: container.layout.menuBarStyle)
            ?? MenuBarIcon.image
            ?? MenuBarStripRenderer.fallbackIcon
    }

    /// strip은 provider당 한 segment — star는 family 설정이라 모든 계정 카드가 같은 pin을 들고 있음.
    /// dashboard가 고른 카드를 먼저 남기고, 그래도 남는 같은 family 카드(관리형이 아닌 config-dir 카드)는 첫 카드만.
    private static func stripGroups(container: AppContainer) -> [ProviderMetrics] {
        // 선택 자체는 `UserDefaults` 값이라 관찰 대상이 아님 — revision을 읽어 picker 변경에 re-arm.
        _ = container.accountSelectionRevision
        let groups = container.layout.pinnedGroups
        let visibleCardIDs = Set(container.collapsingAccountCards(
            groups.map(\.provider.id),
            selectionByFamily: DashboardUsageAccountSelection.storedSelections()
        ))
        var seenFamilies = Set<String>()
        return groups.filter { group in
            guard visibleCardIDs.contains(group.provider.id) else { return false }
            return seenFamilies.insert(ProviderAccountID.family(of: group.provider.id)).inserted
        }
    }
}
