import Foundation

/// 추가 도구의 저장 위치와 수집기 구성. 기존 원장과 계정 API는 각 프로바이더에서 관리.
enum UsageSourceCollectors {
    static func make(environment: EnvironmentReading, home: URL) -> [any UsageCollecting] {
        [PiUsageScanner(environment: environment, homeDirectory: { home })]
    }

    static func configured(_ key: String, environment: EnvironmentReading, home: URL) -> URL? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value)
    }
}
