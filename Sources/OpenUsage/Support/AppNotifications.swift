import AppKit
import Foundation
import UserNotifications

/// macOS 사용자 알림 게시의 단일 진입점.
/// authorization은 `Task<Bool, Never>` 하나로 memoize — 최초 호출만 요청하고 이후 호출은 같은 task를 await.
/// notification-center delegate를 겸해 앱이 frontmost일 때도 배너 표시.
@MainActor
final class AppNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotifications()

    /// 테스트에서 fake center 주입용; production은 시스템 `current()` 반환.
    private let centerProvider: @Sendable () -> UNUserNotificationCenter

    /// memoize된 authorization 요청 — 최초 사용 시 생성, 이후 호출은 모두 await.
    private var authorizationTask: Task<Bool, Never>?

    init(centerProvider: @escaping @Sendable () -> UNUserNotificationCenter = { UNUserNotificationCenter.current() }) {
        self.centerProvider = centerProvider
        super.init()
    }

    /// XCTest harness 실행 여부 — 단위 테스트가 실제 알림 예약이나 authorization prompt를 유발하지 않게 하는 가드.
    /// 앱 타깃에 XCTest 심벌이 링크되지 않으므로 runtime class lookup 사용.
    static var isRunningUnderTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    /// 앱이 frontmost여도 배너가 표시되도록 launch 시 delegate 등록. 테스트에서는 no-op.
    func registerAsDelegate() {
        guard !Self.isRunningUnderTests else { return }
        centerProvider().delegate = self
    }

    /// 알림 authorization 요청. memoize되어 반복 호출해도 재프롬프트 없음.
    @discardableResult
    func requestAuthorization() -> Task<Bool, Never> {
        ensureAuthorization()
    }

    /// macOS 수준 거부 후 사용자가 재허용할 수 있도록 System Settings → Notifications 열기. 테스트에서는 no-op.
    func openSystemNotificationsSettings() {
        guard !Self.isRunningUnderTests else { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 즉시 알림 1건 게시. identifier는 매번 고유해 같은 metric의 반복 알림이 coalesce되지 않음.
    /// 실제 전달 여부 반환(테스트·미허가·예약 실패 시 false) — 호출자가 milestone을 미기록으로 남기고 재시도 가능.
    func post(idPrefix: String, title: String, subtitle: String, body: String, soundEnabled: Bool = true) async -> Bool {
        guard !Self.isRunningUnderTests else { return false }
        var authorized = await ensureAuthorization().value
        if !authorized {
            // 캐시된 거부는 stale일 수 있으므로 live 상태 재확인 — System Settings 재허용이 재시작 없이 반영됨.
            let status = await centerProvider().notificationSettings().authorizationStatus
            switch status {
            case .authorized, .provisional, .ephemeral:
                authorized = true
                authorizationTask = Task<Bool, Never> { true }
            default:
                AppLog.debug(.notifications, "skip \(idPrefix): not authorized")
                return false
            }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        // 동시 알림이 개별 배너 대신 "N more" 요약 하나로 묶이도록 단일 thread로 그룹화.
        content.threadIdentifier = "openusage"
        if soundEnabled { content.sound = .default }
        let id = "openusage-\(idPrefix)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await centerProvider().add(request)
            AppLog.info(.notifications, "posted \(idPrefix)")
            return true
        } catch {
            AppLog.error(.notifications, "post \(idPrefix) failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Authorization

    /// 최초 호출 시 생성되는 공유 authorization task. 확정 상태(authorized/denied)는 short-circuit,
    /// notDetermined일 때만 alert + sound 권한 요청.
    private func ensureAuthorization() -> Task<Bool, Never> {
        if let authorizationTask { return authorizationTask }
        let center = centerProvider()
        let task = Task<Bool, Never> {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                return true
            case .denied:
                AppLog.info(.notifications, "authorization denied")
                return false
            case .notDetermined:
                do {
                    let granted = try await center.requestAuthorization(options: [.alert, .sound])
                    AppLog.info(.notifications, "authorization \(granted ? "granted" : "refused")")
                    return granted
                } catch {
                    AppLog.error(.notifications, "authorization request failed: \(error.localizedDescription)")
                    return false
                }
            @unknown default:
                return false
            }
        }
        authorizationTask = task
        return task
    }

    /// Settings 화면의 거부 안내용 현재 authorization 상태. 테스트에서는 `.notDetermined` 반환.
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard !Self.isRunningUnderTests else { return .notDetermined }
        return await centerProvider().notificationSettings().authorizationStatus
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 앱이 frontmost여도 배너·사운드 표시 — menu-bar accessory는 사실상 항상 frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// pace 알림 탭 시 menu-bar popover 열기.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              response.notification.request.content.threadIdentifier == "openusage"
        else {
            completionHandler()
            return
        }
        Task { @MainActor in
            AppLog.info(.notifications, "notification tapped; opening popover")
            MenuBarPopover.show()
        }
        completionHandler()
    }
}
