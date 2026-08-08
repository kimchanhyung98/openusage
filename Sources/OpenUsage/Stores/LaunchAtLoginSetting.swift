import Observation
import ServiceManagement

/// Launch at Login 스위치를 macOS 상태와 동기화
/// 실패한 rollback을 두 번째 사용자 액션으로 취급하지 않는 규칙
@MainActor
@Observable
final class LaunchAtLoginSetting {
    static let failureMessage = "macOS wouldn't update Launch at Login. Check System Settings → Login Items."

    private(set) var isEnabled: Bool
    private(set) var errorMessage: String?

    private let currentStatus: () -> Bool
    private let setSystemEnabled: (Bool) throws -> Void

    init(
        currentStatus: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled },
        setEnabled: @escaping (Bool) throws -> Void = { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.currentStatus = currentStatus
        self.setSystemEnabled = setEnabled
        self.isEnabled = currentStatus()
    }

    func update(to enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try setSystemEnabled(enabled)
            isEnabled = currentStatus()
            errorMessage = nil
        } catch {
            AppLog.error(
                .config,
                "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            isEnabled = currentStatus()
            errorMessage = Self.failureMessage
        }
    }
}
