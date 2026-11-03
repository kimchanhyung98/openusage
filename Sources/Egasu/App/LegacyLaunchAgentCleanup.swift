import Foundation

/// 레거시 Tauri 에디션이 남긴 autostart LaunchAgent(`~/Library/LaunchAgents/OpenUsage.plist`) 삭제 — 로그인 이중 실행 원인 (#607/#874).
/// 제거 판정은 보수적 — program이 이 앱 bundle 내부를 가리킬 때만 삭제, 그 외는 방치·로그.
/// 의도적으로 파일 삭제만 수행 — `launchctl bootout`은 agent가 띄운 현재 process를 SIGTERM할 위험.
enum LegacyLaunchAgentCleanup {
    /// 제거 판정에 필요한 레거시 plist 선언부. `programPath`는 `Program` key, 없으면 `ProgramArguments` 첫 요소.
    struct Agent: Equatable {
        var programPath: String?
    }

    /// `tauri-plugin-autostart`가 product name으로 명명한 plist 경로.
    static var defaultAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/OpenUsage.plist")
    }

    /// 런치당 1회 호출되는 live entry point. 파라미터는 테스트 전용.
    static func removeLeftoverAgent(
        agentURL: URL = defaultAgentURL,
        bundlePath: String = Bundle.main.bundlePath
    ) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: agentURL.path) else { return }

        let agent: Agent
        do {
            agent = try parse(plistData: Data(contentsOf: agentURL))
        } catch {
            AppLog.error(.lifecycle, "found \(agentURL.path) but couldn't read it: \(error.localizedDescription)")
            return
        }

        guard shouldRemove(programPath: agent.programPath, bundlePath: bundlePath) else {
            AppLog.info(.lifecycle, "leaving \(agentURL.path) alone — its program (\(agent.programPath ?? "unset")) is outside this app bundle")
            return
        }

        do {
            try fileManager.removeItem(at: agentURL)
            AppLog.info(.lifecycle, "removed legacy Tauri autostart agent \(agentURL.path) — it pointed into this app bundle and double-launched the app at login (#874)")
        } catch {
            AppLog.error(.lifecycle, "couldn't delete legacy autostart agent \(agentURL.path): \(error.localizedDescription) — will retry next launch")
        }
    }

    /// 순수 제거 판정: agent의 program이 이 앱 `.app` bundle 내부일 때만 true.
    /// APFS 기본을 따라 대소문자 무시 비교; `.app` suffix 요구로 unbundled 실행(`swift run`) 미매칭.
    static func shouldRemove(programPath: String?, bundlePath: String) -> Bool {
        guard let programPath else { return false }
        let bundle = (bundlePath as NSString).standardizingPath
        guard bundle.hasSuffix(".app") else { return false }
        let program = (programPath as NSString).standardizingPath
        return program.lowercased().hasPrefix(bundle.lowercased() + "/")
    }

    /// launchd plist에서 실행 파일 추출. 비-plist 데이터는 throw; 키 부재 시 `programPath` nil (제거 판정에서 방치 취급).
    static func parse(plistData: Data) throws -> Agent {
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil)
        guard let dict = plist as? [String: Any] else {
            return Agent(programPath: nil)
        }
        let program = dict["Program"] as? String
            ?? (dict["ProgramArguments"] as? [String])?.first
        return Agent(programPath: program)
    }
}
