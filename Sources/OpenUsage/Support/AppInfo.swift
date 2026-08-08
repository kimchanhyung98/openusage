import Foundation

/// 대시보드 footer와 About 탭에 표시되는 앱 버전의 단일 소스.
/// `CFBundleShortVersionString`은 pre-release suffix까지 포함한 전체 버전; fallback은 Info.plist가 없는 실행(`swift run`) 대비.
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.9.0-dev"
    }
}
