import AppKit

/// 앱 전체 appearance override, `.system`은 macOS 추종
/// panel hosting이 SwiftUI `preferredColorScheme`을 무시하므로 `NSApp.appearance` 수준에서 적용
/// 메뉴바 panel 동기화는 `applyCurrent()`의 `didChangeNotification` 게시로 처리
enum AppearanceSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case system
    case light
    case dark

    static let key = "appearance"
    static var fallback: AppearanceSetting { .system }

    /// 앱 수준 appearance 적용 후 게시 — popover 소유자가 메뉴바 panel에 동일 override 반영
    static let didChangeNotification = Notification.Name("AppearanceSettingDidChange")

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// `.system`은 `nil` — OS 설정 상속으로 재적용 없이 라이브 테마 전환 추종
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    // `current`(저장된 선택값, 미설정 시 `.system`)는 `UserDefaultsBacked` 제공

    /// 저장된 선택값을 앱 전역에 적용 — 런칭 시 1회, 설정 변경 시마다 호출
    @MainActor
    static func applyCurrent() {
        NSApplication.shared.appearance = current.nsAppearance
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
