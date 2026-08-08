import Foundation

/// file log를 gate하는 persisted log level
/// key와 raw value는 원본 Tauri store와 동일 유지 — 두 edition 간 grep 호환 목적
/// `Trace`·`off` 미노출, fallback은 릴리스 기본값 `.info` (Debug는 opt-in 전용)
enum LogLevelSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case error
    case warn
    case info
    case debug

    /// Tauri store key 공유 — 두 edition이 서로의 store를 읽지 않으므로 무해
    static let key = "logLevel"

    /// key 미설정·미인식 raw value 시 사용값 — Debug는 암묵 기본값이 될 수 없음
    static var fallback: LogLevelSetting { .info }

    var label: String {
        switch self {
        case .error: "Error"
        case .warn: "Warning"
        case .info: "Info"
        case .debug: "Debug"
        }
    }

    /// 값이 클수록 verbose — `lineLevel.severity <= self.severity`일 때 file에 기록
    var severity: Int {
        switch self {
        case .error: 0
        case .warn: 1
        case .info: 2
        case .debug: 3
        }
    }
}
