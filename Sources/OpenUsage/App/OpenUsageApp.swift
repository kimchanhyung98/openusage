import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    private var singleInstanceLock: SingleInstanceLock.Token?
    private let updater = UpdaterController()

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 다른 로그보다 먼저 bootstrap — 세션 첫 라인 캡처.
        AppLog.bootstrap()
        // 커널 수준 single-instance lock (#874) — workspace guard snapshot이 놓치는 근접 동시 런치도 차단.
        var holdsLock = false
        if let bundleID = Bundle.main.bundleIdentifier {
            switch SingleInstanceLock.acquire(bundleIdentifier: bundleID) {
            case .acquired(let token):
                singleInstanceLock = token
                holdsLock = true
            case .alreadyRunning:
                SingleInstanceGuard.activateExistingInstance()
                AppLog.info(.lifecycle, "duplicate launch detected by process lock; terminating")
                NSApp.terminate(nil)
                return
            case .failed(let message):
                AppLog.error(.lifecycle, "single-instance lock unavailable: \(message)")
            }
        }
        // lock 승자는 workspace guard 미참조 필수 — snapshot의 mid-exit 패자에 양보하면 zero instance (#874);
        // guard는 unbundled 런치·lock 실패의 fallback 전용. `terminate(_:)`는 비동기 unwind — 여기서 return 필수.
        if !holdsLock, SingleInstanceGuard.deferToExistingInstance() {
            AppLog.info(.lifecycle, "duplicate launch detected; handing off to the running instance and terminating")
            NSApp.terminate(nil)
            return
        }
        // 버전드 settings migration. UserDefaults를 읽고 쓰는 모든 코드보다 먼저 실행 필수 —
        // fresh-install 판정은 migrate 전에 캡처 (schema stamp가 도메인을 non-empty로 변경). `SettingsMigrator` 참고.
        let isFreshInstall = SettingsMigrator.isFreshInstall()
        SettingsMigrator.migrate()
        // 시작은 `SMAppService` login item 단독 담당 — AppKit reopen-on-login opt-out으로 재부팅 시 이중 런치 예방.
        NSApp.disableRelaunchOnLogin()
        // 레거시 Tauri autostart agent 정리 — 로그인 이중 실행 원인 (#607/#874). guard 이후 실행 필수 — 생존 copy만 파일 접근.
        LegacyLaunchAgentCleanup.removeLeftoverAgent()
        // 앱 전역 theme override는 AppKit 수준 적용 — popover가 SwiftUI `preferredColorScheme` 미준수.
        AppearanceSetting.applyCurrent()
        let container = AppContainer(isFreshInstall: isFreshInstall)
        self.container = container
        statusItemController = StatusItemController(container: container, updater: updater)
        // 백그라운드 업데이트 체크 시작 (release build 한정).
        updater.start()
    }

    /// 종료 시 대기 telemetry flush — SDK lifecycle autocapture off라 자동 flush 부재, 저빈도 이벤트 유실 방지.
    public func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }
}
