import Foundation

/// pi가 이 기기에 session 로그를 두는 위치 — 해석은 pi 자신과 동일: `PI_CODING_AGENT_SESSION_DIR` 우선, 다음 `PI_CODING_AGENT_DIR/sessions`(config-dir override), 마지막 기본 `~/.pi/agent/sessions`.
/// pi는 working-directory별 하위 폴더에 session당 `*.jsonl` 하나를 기록 — 디렉토리는 재귀 스캔.
enum PiPaths {
    static func sessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL {
        if let override = environment.value(for: "PI_CODING_AGENT_SESSION_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(override))
        }
        if let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: expandHome(configDir)).appendingPathComponent("sessions")
        }
        return homeDirectory.appendingPathComponent(".pi/agent/sessions")
    }
}
