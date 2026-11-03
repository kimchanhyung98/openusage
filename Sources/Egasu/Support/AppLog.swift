import Foundation
import os

/// 모든 로그 라인 앞에 붙는 grep 친화적 subsystem 태그. raw value가 bracket 텍스트이자 `os.Logger` category.
enum LogTag: String, Sendable {
    case refresh
    case cache
    case http
    case auth
    case keychain
    case menubar
    case updates
    case config
    case statusItem = "statusitem"
    case localAPI = "localapi"
    case subprocess
    case lifecycle
    case notifications

    /// provider별 라인용 `[plugin:<id>]` / `[auth:<id>]` 복합 태그.
    static func plugin(_ id: String) -> String { "plugin:\(id)" }
    static func auth(_ id: String) -> String { "auth:\(id)" }
}

/// 통합 로깅 파사드 — `LogLevelSetting` 하나가 `os.Logger`와 `LogFile` 두 sink의 공통 level floor.
/// floor 미달 라인은 메시지 생성·redaction 전에 드롭되고, error(severity 0)는 floor와 무관하게 항상 기록.
/// `redactLogMessage`는 URL/body를 모름 — URL이나 응답 body를 로그하는 호출부는 `LogRedaction.redactURL`/`bodyPreview`로 선-redaction 필수.
enum AppLog {
    private enum Level: Int {
        case error = 0
        case warn = 1
        case info = 2
        case debug = 3

        var label: String {
            switch self {
            case .error: "ERROR"
            case .warn: "WARN"
            case .info: "INFO"
            case .debug: "DEBUG"
            }
        }

        var osType: OSLogType {
            switch self {
            case .error: .error
            case .warn: .default
            case .info: .info
            case .debug: .debug
            }
        }
    }

    /// lock으로 보호되는 level floor 캐시(severity 서수) — 어떤 isolation에서도 저렴하게 읽기 가능.
    private static let levelLock = NSLock()
    private nonisolated(unsafe) static var cachedSeverity = LogLevelSetting.fallback.severity

    /// category별 `os.Logger` 캐시.
    private static let loggerLock = NSLock()
    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

    /// file sink. 테스트에서 임시 디렉터리로 주입 가능; production은 공유 `~/Library/Logs/OpenUsage/OpenUsage.log` appender.
    nonisolated(unsafe) static var sink: LogFile = .shared

    // MARK: - Lifecycle

    /// 파일 open/trim, level 캐시 seed, 시작 라인 1줄 기록. 다른 subsystem이 로그하기 전 launch 최우선 호출 필요.
    static func bootstrap() {
        sink.open()
        reloadLevel()
        let level = LogLevelSetting.current
        // `$HOME`을 `~`로 축약해 경로가 `redactLogMessage`의 `/Users/...` 마스킹을 통과하도록 함.
        let displayPath = (LogFile.url.path as NSString).abbreviatingWithTildeInPath
        info(LogTag.config.rawValue,
             "OpenUsage v\(AppInfo.version) starting (level=\(level.rawValue), log=\(displayPath))")
    }

    /// 저장된 level을 캐시로 재적재. Settings picker `.onChange`에서 호출되어 재시작 없이 즉시 반영.
    static func reloadLevel() {
        apply(LogLevelSetting.current.severity)
    }

    /// `UserDefaults`를 우회해 level을 직접 적용하는 테스트용 seam.
    static func reloadLevel(_ level: LogLevelSetting) {
        apply(level.severity)
    }

    private static func apply(_ severity: Int) {
        levelLock.lock()
        cachedSeverity = severity
        levelLock.unlock()
    }

    // MARK: - Public API

    /// `@autoclosure`로 interpolation 지연 — floor 미달 라인은 메시지 생성 비용 자체가 없음.
    static func error(_ tag: String, _ message: @autoclosure () -> String) { emit(.error, tag, message) }
    static func warn(_ tag: String, _ message: @autoclosure () -> String) { emit(.warn, tag, message) }
    static func info(_ tag: String, _ message: @autoclosure () -> String) { emit(.info, tag, message) }
    static func debug(_ tag: String, _ message: @autoclosure () -> String) { emit(.debug, tag, message) }

    // 타입 태그용 편의 overload.
    static func error(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.error, tag.rawValue, message) }
    static func warn(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.warn, tag.rawValue, message) }
    static func info(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.info, tag.rawValue, message) }
    static func debug(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.debug, tag.rawValue, message) }

    // MARK: - Emit

    private static func emit(_ level: Level, _ tag: String, _ message: () -> String) {
        // floor gate 우선: 미달 라인은 메시지 생성·redaction·sink 없이 드롭, error(severity 0)는 항상 통과.
        levelLock.lock()
        let floor = cachedSeverity
        levelLock.unlock()
        guard level.rawValue <= floor else { return }

        let redacted = LogRedaction.redactLogMessage(message())

        logger(for: tag).log(level: level.osType, "[\(tag, privacy: .public)] \(redacted, privacy: .public)")

        let timestamp = OpenUsageISO8601.string(from: Date())
        sink.append("\(timestamp) [\(level.label)] [\(tag)] \(redacted)")
    }

    private static func logger(for tag: String) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = loggers[tag] { return existing }
        let logger = Logger(subsystem: "OpenUsage", category: tag)
        loggers[tag] = logger
        return logger
    }
}
