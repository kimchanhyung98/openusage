import AppKit
import Combine
import Foundation
import Observation
import Sparkle

/// Sparkle standard updater의 wrapper — 앱의 나머지는 Sparkle 비의존 유지.
/// `SUFeedURL`을 선언한 패키지 bundle에서만 동작 — signed release build 한정, `swift run`·dev build는 dormant.
@MainActor
@Observable
final class UpdaterController {
    /// beta 채널 opt-in의 `UserDefaults` key. SwiftUI 토글과 Sparkle channel delegate가 함께 읽는 단일 source of truth.
    static let betaChannelDefaultsKey = "betaUpdatesEnabled"

    // delegate 2개 분리 필수 — SPUUpdaterDelegate는 main-actor, SPUStandardUserDriverDelegate는 nonisolated;
    // 한 클래스 겸용 시 Swift 6에서 한쪽 conformance 파손.
    private let channelDelegate = UpdaterChannelDelegate()
    private let userDriverDelegate = UpdaterUserDriverDelegate()
    private let presentationController: UpdaterPresentationController
    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?

    /// 실제 updater 동작 여부 (feed 있는 release build). Settings의 Updates 섹션 표시 여부 결정.
    private(set) var isActive = false
    /// Sparkle KVO `canCheckForUpdates`의 미러 — "Check for Updates…" 버튼 활성 상태 주도.
    private(set) var canCheckForUpdates = false
    /// scheduled check가 찾은 업데이트의 표시 버전, 없으면 `nil`.
    /// Sparkle window 대신 dashboard 배너로 노출 — dockless 앱에서 window가 뒤로 밀리는 문제 회피.
    private(set) var availableUpdateVersion: String?

    /// "Beta Updates" 토글 backing. `UserDefaults` 영속; flip 시 update cycle reset — 새 채널이 다음 check에 즉시 반영.
    var betaChannelEnabled: Bool {
        didSet {
            UserDefaults.standard.set(betaChannelEnabled, forKey: Self.betaChannelDefaultsKey)
            controller?.updater.resetUpdateCycle()
            AppLog.info(.updates, "channel set to \(self.betaChannelEnabled ? "early access" : "stable")")
        }
    }

    /// "Update Automatically" 토글 backing. Sparkle이 자체 영속 — shadow preference 아닌 pass-through.
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    init(presentationController: UpdaterPresentationController = UpdaterPresentationController()) {
        self.presentationController = presentationController
        self.betaChannelEnabled = UserDefaults.standard.bool(forKey: Self.betaChannelDefaultsKey)
    }

    /// appcast feed가 있는 build에서만 updater 시작. 런치 시 1회 호출 안전.
    func start() {
        guard controller == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            AppLog.info(.updates, "disabled: no SUFeedURL (unbundled or dev build)")
            return
        }
        // driver delegate는 nonisolated, callback은 main thread — hop으로 배너 상태를 이 controller에 publish.
        userDriverDelegate.onUpdateFound = { [weak self] version in
            self?.availableUpdateVersion = version
            AppLog.info(.updates, "scheduled check found \(version); showing in-app banner")
        }
        userDriverDelegate.onUpdateResolved = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        userDriverDelegate.onUpdateWillShow = { [weak self] in
            self?.presentationController.bringToFront(reason: "Sparkle will show update")
        }
        userDriverDelegate.onUpdateSessionFinished = { [weak self] in
            self?.presentationController.returnToMenuBar()
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: channelDelegate,
            userDriverDelegate: userDriverDelegate
        )
        self.controller = controller
        isActive = true
        // Sparkle KVO를 `@Observable` 상태로 bridge. main queue 강제 delivery — 아래 main-actor 변경이 항상 유효.
        canCheckForUpdates = controller.updater.canCheckForUpdates
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        AppLog.info(.updates, "started (feed present)")
    }

    /// 사용자 시작 check — Sparkle 표준 UI 표시.
    func checkForUpdates() {
        guard let controller else { return }
        // Sparkle에 제어를 넘기기 전 선-foreground — activation-policy 전환이 checking window를 뒤에 남기지 않도록.
        // 다음 run loop로 넘겨 activation-policy 전환 직후 checking window가 뒤에 남는 문제 회피.
        presentationController.bringToFront(reason: "user initiated check")
        DispatchQueue.main.async {
            controller.checkForUpdates(nil)
        }
    }

    /// 배너의 install 액션 — 사용자 시작 check로 라우팅, 업데이트가 유효하면 Sparkle이 frontmost로 재표시.
    func installAvailableUpdate() {
        checkForUpdates()
    }

    /// 배너 dismiss — snooze 성격. 다음 scheduled check가 재노출 (영구 skip은 Sparkle window 담당).
    func dismissAvailableUpdate() {
        availableUpdateVersion = nil
    }
}

/// dockless 메뉴 바 앱에서 Sparkle 표시에 필요한 좁은 AppKit 경계 소유.
/// `NSApplication.activate()`는 다른 앱이 활성화된 상태의 dockless 앱에서 불안정해 `ignoringOtherApps` API 사용.
/// 주입 closure로 macOS focus 자동화 없이 단위 테스트 가능.
@MainActor
final class UpdaterPresentationController {
    private let activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let isActive: @MainActor () -> Bool
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let activate: @MainActor (Bool) -> Void

    convenience init(application: NSApplication = .shared) {
        self.init(
            activationPolicy: { application.activationPolicy() },
            isActive: { application.isActive },
            setActivationPolicy: { application.setActivationPolicy($0) },
            activate: { application.activate(ignoringOtherApps: $0) }
        )
    }

    init(
        activationPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
        isActive: @escaping @MainActor () -> Bool,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool,
        activate: @escaping @MainActor (Bool) -> Void
    ) {
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
    }

    func bringToFront(reason: String) {
        let beforePolicy = activationPolicy()
        let beforeActive = isActive()
        let policyChanged = setActivationPolicy(.regular)
        activate(true)
        AppLog.info(
            .updates,
            "foreground updater (reason=\(reason), policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(beforeActive)->\(isActive()), policyChanged=\(policyChanged))"
        )
    }

    func returnToMenuBar() {
        let beforePolicy = activationPolicy()
        let policyChanged = setActivationPolicy(.accessory)
        AppLog.info(
            .updates,
            "finish updater presentation (policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(isActive()), policyChanged=\(policyChanged))"
        )
    }
}

/// 채널 선택 delegate. `SPUUpdaterDelegate`가 Sparkle에서 main-actor라 이 delegate도 main-actor — defaults key 직접 접근 가능.
@MainActor
private final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    /// 기본은 stable 채널. `["beta"]` 반환은 pre-release 추가 opt-in — Sparkle이 기본 채널을 항상 포함해 stable 릴리스 미차단.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? ["beta"] : []
    }

    /// update cycle 결과 기록. `SUNoUpdateError`/`SUInstallationCanceledError`는 정상 outcome이라 Info, 실제 오류만 Warn.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        let channel = UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? "early access" : "stable"
        guard let error else {
            AppLog.info(.updates, "check finished (channel=\(channel), no error)")
            return
        }
        let code = (error as NSError).code
        if code == Int(SUError.noUpdateError.rawValue) {
            AppLog.info(.updates, "check finished (channel=\(channel), no update available)")
        } else if code == Int(SUError.installationCanceledError.rawValue) {
            AppLog.info(.updates, "check finished (channel=\(channel), user canceled)")
        } else {
            AppLog.warn(.updates, "check/download failed: \(error.localizedDescription)")
        }
    }
}

/// accessory 앱 activation 처리 delegate. `SPUStandardUserDriverDelegate`가 Sparkle에서 nonisolated —
/// callback은 main thread라 `NSApp` 접근에 main-actor assume.
final class UpdaterUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// scheduled check의 발견 버전을 `UpdaterController`(main actor)에 publish — dashboard 배너로 렌더.
    var onUpdateFound: (@MainActor @Sendable (String) -> Void)?
    /// 배너 해제 — 사용자가 업데이트에 주의를 주었거나 세션 종료.
    var onUpdateResolved: (@MainActor @Sendable () -> Void)?
    /// Sparkle의 update UI 표시 직전 foreground 재확보.
    var onUpdateWillShow: (@MainActor @Sendable () -> Void)?
    /// 세션 종료 후 dockless activation policy 복원.
    var onUpdateSessionFinished: (@MainActor @Sendable () -> Void)?

    /// "gentle" reminder opt-in — scheduled check에서 Sparkle의 focus 탈취 alert 방지.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// scheduled update 표시를 전면 인수 — dockless 앱은 Sparkle window가 뒤로 밀리므로 `onUpdateFound` 경유 in-popover 배너로 대체.
    /// 사용자 시작 check는 이 메서드 미경유 — Sparkle이 직접 전면 표시.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// update UI 표시 동안만 regular 앱 전환 — accessory 앱은 Sparkle window가 focus 없이 뒤에 열림.
    /// Sparkle이 실제 window를 보일 때(`handleShowingUpdate`)만 전환 — 거절된 scheduled update는 배너 publish만
    /// (그때 `.regular` 전환은 빈 Dock icon flash).
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        // main-actor closure가 nonisolated `self` 대신 Sendable callback만 캡처하도록 hoist (Swift 6 region isolation).
        let onUpdateFound = onUpdateFound
        let onUpdateWillShow = onUpdateWillShow
        MainActor.assumeIsolated {
            guard handleShowingUpdate else {
                onUpdateFound?(version)
                return
            }
            onUpdateWillShow?()
        }
    }

    /// 사용자가 이 업데이트의 Sparkle window에 도달 — 배너 임무 완료, 해제.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        let onUpdateResolved = onUpdateResolved
        MainActor.assumeIsolated { () -> Void in
            onUpdateResolved?()
        }
    }

    /// update 세션 종료 시 메뉴 바 전용 앱으로 복귀 + 잔여 in-app indicator 해제.
    func standardUserDriverWillFinishUpdateSession() {
        let onUpdateResolved = onUpdateResolved
        let onUpdateSessionFinished = onUpdateSessionFinished
        MainActor.assumeIsolated { () -> Void in
            onUpdateSessionFinished?()
            onUpdateResolved?()
        }
    }
}
