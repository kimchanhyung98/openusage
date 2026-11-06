import Foundation

/// 추가 도구의 저장 위치와 수집기 구성. 기존 원장과 계정 API는 각 프로바이더에서 관리.
enum UsageSourceCollectors {
    static func make(environment: EnvironmentReading, home: URL) -> [any UsageCollecting] {
        let dsh = configured("DSH_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".dsh")
        let clawRoots = openClawRoots(environment: environment, home: home)
        let hermes = configured("HERMES_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".hermes")
        let hermesProfiles = hermes.appendingPathComponent("profiles")
        let hermesPath = hermes.resolvingSymlinksInPath().path
        let hermesProfilesPath = hermesProfiles.resolvingSymlinksInPath().path
        let hermesRoots = hermes.deletingLastPathComponent().lastPathComponent == "profiles"
            ? [hermes.appendingPathComponent("state.db")] : [hermes.appendingPathComponent("state.db"), hermesProfiles]
        return [
            PiUsageScanner(environment: environment, homeDirectory: { home }),
            UsageFileCollector(
                sourceID: "openclaw", roots: clawRoots, version: 2, includeFile: {
                    let name = $0.lastPathComponent
                    return ($0.path.contains("/sessions/") || $0.path.contains("/session-sqlite-import-archive/"))
                        && !$0.path.contains("/sessions/cold/") && !name.contains(".checkpoint.")
                        && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst") || name.contains(".jsonl.deleted.") || name.contains(".jsonl.reset."))
                }, parse: OpenClawSessionParser.parse
            ),
            UsageSQLiteCollector(sourceID: "openclaw", roots: clawRoots,
                                 includeFile: { $0.lastPathComponent == "openclaw-agent.sqlite" }, parse: OpenClawSessionParser.database),
            UsageSQLiteCollector(sourceID: "hermes", roots: hermesRoots, includeFile: { url in
                guard url.lastPathComponent == "state.db" else { return false }
                let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
                return parent.path == hermesPath || parent.deletingLastPathComponent().path == hermesProfilesPath
            }, parse: HermesUsageParser.database),
            UsageFileCollector(sourceID: "dsh", roots: [dsh.appendingPathComponent("sessions")],
                               includeFile: DeepSeekSessionParser.isCurrentGeneration, parse: DeepSeekSessionParser.parse)
        ]
    }

    static func openClawRoots(environment: EnvironmentReading, home: URL) -> [URL] {
        let base = configured("OPENCLAW_HOME", environment: environment, home: home) ?? home
        if let state = configured("OPENCLAW_STATE_DIR", environment: environment, home: base) {
            return [state.appendingPathComponent("agents")]
        }
        if let profile = environment.value(for: "OPENCLAW_PROFILE")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           profile.lowercased() != "default", profile.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil {
            return [base.appendingPathComponent(".openclaw-\(profile)/agents")]
        }
        return [".openclaw", ".clawdbot", ".moltbot", ".moldbot"].map { base.appendingPathComponent($0 + "/agents") }
    }

    static func configured(_ key: String, environment: EnvironmentReading, home: URL) -> URL? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value)
    }
}
