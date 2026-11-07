import Foundation
import Observation

/// 메뉴바 screen-share privacy mode의 단일 출처 — persisted "Hide From Screen Share" 설정과 라이브 캡처 신호
/// 저장 완료된 conceal edge를 `StatusItemImageUpdater`에 전달해 캡처 시작·종료 즉시 wordmark 전환
/// monitoring은 설정 on일 때만 — poll(보증)과 window server watcher 알림(fast path, best-effort) 병행
@MainActor
@Observable
final class MenuBarPrivacyStore {
    static let key = "hideUsageWhileScreenSharing"

    /// 설정 on 동안의 poll 주기 — 알림 유실 시 노출을 수 초로 제한, 검사 자체는 저비용 window-server 호출 1회
    static let pollInterval: Duration = .seconds(3)

    /// persisted 설정 (기본 on) — view-local `@AppStorage` 대신 여기 저장해 AppKit strip renderer와 값 일치 보장
    /// toggle이 monitoring을 시작·중지하므로 off 상태 비용 없음
    var hideUsageWhileScreenSharing: Bool {
        didSet {
            guard hideUsageWhileScreenSharing != oldValue else { return }
            defaults.set(hideUsageWhileScreenSharing, forKey: Self.key)
            if hideUsageWhileScreenSharing {
                startMonitoring()
            } else {
                stopMonitoring()
            }
            publishConcealUsageChange()
        }
    }

    /// 현재 캡처 활성 여부 — 설정 on 동안만 유지, 그 외 항상 `false`
    private(set) var screenIsCaptured = false

    /// 메뉴바가 usage 대신 wordmark를 보여야 하는 정확한 조건
    var concealUsage: Bool { hideUsageWhileScreenSharing && screenIsCaptured }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probe: @MainActor () -> Bool
    @ObservationIgnored private let installChangeNotifications: @MainActor (@escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var concealUsageObserver: ((Bool) -> Void)?
    @ObservationIgnored private var lastPublishedConcealUsage: Bool?

    /// probe·알림 installer는 실제 window-server 신호(`ScreenCaptureProbe`)가 기본값, 테스트 주입용으로 교체 가능
    init(
        defaults: UserDefaults = .standard,
        probe: @escaping @MainActor () -> Bool = ScreenCaptureProbe.isScreenCaptured,
        installChangeNotifications: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void = ScreenCaptureProbe.installChangeNotifications
    ) {
        self.defaults = defaults
        self.probe = probe
        self.installChangeNotifications = installChangeNotifications
        self.hideUsageWhileScreenSharing = defaults.bool(forKey: Self.key, default: true)
        // init 중에는 `didSet` 미발동 — persisted-on launch는 직접 monitoring 시작
        if hideUsageWhileScreenSharing {
            startMonitoring()
        }
    }

    deinit { pollTask?.cancel() }

    /// 메뉴바 image consumer 하나 등록 — 이후 derived conceal edge를 저장 완료 순서대로 전달.
    func setConcealUsageObserver(_ observer: @escaping (Bool) -> Void) {
        concealUsageObserver = observer
        lastPublishedConcealUsage = concealUsage
    }

    /// watcher flag 재확인 후 변경 게시 — poll·monitoring 시작 경로
    /// 설정을 경유해 읽으므로 toggle off 후 도착한 stale 알림이 재은폐 불가
    func refreshCaptureState() {
        applyCaptureState(hideUsageWhileScreenSharing && probe())
    }

    private func applyCaptureState(_ captured: Bool) {
        guard captured != screenIsCaptured else { return }
        screenIsCaptured = captured
        publishConcealUsageChange()
        AppLog.info(.menubar, captured
            ? "Screen capture detected; menu bar shows the wordmark"
            : "Screen capture ended; menu bar shows usage again")
    }

    private func startMonitoring() {
        guard pollTask == nil else { return }
        installChangeNotifications { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCaptureState()
            }
        }
        refreshCaptureState()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refreshCaptureState()
            }
        }
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        if screenIsCaptured {
            screenIsCaptured = false
        }
        publishConcealUsageChange()
    }

    private func publishConcealUsageChange() {
        guard let concealUsageObserver else { return }
        let current = concealUsage
        guard current != lastPublishedConcealUsage else { return }
        lastPublishedConcealUsage = current
        concealUsageObserver(current)
    }
}
