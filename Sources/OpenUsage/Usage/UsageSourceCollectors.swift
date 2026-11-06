import Foundation

/// 추가 도구의 저장 위치와 수집기 구성. 기존 원장과 계정 API는 각 프로바이더에서 관리.
enum UsageSourceCollectors {
    static func make(environment: EnvironmentReading, home: URL) -> [any UsageCollecting] {
        let geminiHome = configured("GEMINI_CLI_HOME", environment: environment, home: home) ?? home
        let qwen = configured("QWEN_RUNTIME_DIR", environment: environment, home: home)
            ?? configured("QWEN_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".qwen")
        let dsh = configured("DSH_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".dsh")
        let clawRoots = openClawRoots(environment: environment, home: home)
        let hermes = configured("HERMES_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".hermes")
        return [
            PiUsageScanner(environment: environment, homeDirectory: { home }),
            UsageFileCollector(
                sourceID: "gemini", providerID: "gemini", roots: [
                    geminiHome.appendingPathComponent(".gemini/tmp"), geminiHome.appendingPathComponent(".cache/.gemini/tmp")
                ], version: 3, includeFile: { $0.path.contains("/chats/") && ["json", "jsonl"].contains($0.pathExtension) },
                parse: GeminiSessionParser.parse
            ),
            qwenCollector(root: qwen),
            openClawCollector(roots: clawRoots),
            openClawDatabaseCollector(roots: clawRoots),
            hermesCollector(root: hermes),
            UsageFileCollector(sourceID: "dsh", roots: [dsh.appendingPathComponent("sessions")], version: 2,
                               includeFile: DeepSeekSessionParser.isCurrentGeneration, parse: DeepSeekSessionParser.parse)
        ]
    }

    static func qwenCollector(
        root: URL, scanner: IncrementalJSONLScanner<UsageRecord>? = nil
    ) -> UsageFileCollector {
        UsageFileCollector(
            sourceID: "qwen", providerID: "qwen", roots: [root.appendingPathComponent("projects")], version: 3,
            scanner: scanner, canReuseCachedFile: QwenSessionParser.canReuseCachedFile,
            includeFile: { $0.path.contains("/chats/") && $0.pathExtension == "jsonl" },
            parse: { data, path in try QwenSessionParser.parse(data, path: path, resources: root.appendingPathComponent("resources")) }
        )
    }

    static func openClawCollector(
        roots: [URL], scanner: IncrementalJSONLScanner<UsageRecord>? = nil
    ) -> UsageFileCollector {
        UsageFileCollector(
            sourceID: "openclaw", roots: roots, version: 2, scanner: scanner,
            includeFile: { isOpenClawTranscript($0, roots: roots) }, parse: OpenClawSessionParser.parse
        )
    }

    private static func isOpenClawTranscript(_ url: URL, roots: [URL]) -> Bool {
        let name = url.lastPathComponent
        guard !name.contains(".checkpoint."), !name.hasSuffix(".tmp"),
              name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst")
                || name.contains(".jsonl.deleted.") || name.contains(".jsonl.reset.") else { return false }
        let path = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(name).path
        return roots.contains { root in
            // 파일 링크 이름은 유지하고 루트 링크의 현재 대상을 기준으로 소속 판정.
            let prefix = root.resolvingSymlinksInPath().path + "/"
            guard path.hasPrefix(prefix) else { return false }
            let relative = "/" + root.lastPathComponent + "/" + String(path.dropFirst(prefix.count))
            return (relative.contains("/sessions/") || relative.contains("/session-sqlite-import-archive/"))
                && !relative.contains("/sessions/cold/")
        }
    }

    static func hermesCollector(root hermes: URL) -> UsageSQLiteCollector {
        let hermesProfiles = hermes.appendingPathComponent("profiles")
        let hermesRoots = hermes.deletingLastPathComponent().lastPathComponent == "profiles"
            ? [hermes.appendingPathComponent("state.db")] : [hermes.appendingPathComponent("state.db"), hermesProfiles]
        return UsageSQLiteCollector(sourceID: "hermes", roots: hermesRoots, includeFile: { url in
            let hermesPath = hermes.resolvingSymlinksInPath().path
            let hermesPrimary = hermes.appendingPathComponent("state.db").resolvingSymlinksInPath().path
            let hermesProfilesPath = hermesProfiles.resolvingSymlinksInPath().path
            if url.resolvingSymlinksInPath().path == hermesPrimary { return true }
            guard url.lastPathComponent == "state.db" else { return false }
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
            return parent.path == hermesPath || parent.deletingLastPathComponent().path == hermesProfilesPath
        }, parse: HermesUsageParser.database)
    }

    static func openClawDatabaseCollector(roots: [URL]) -> UsageSQLiteCollector {
        UsageSQLiteCollector(sourceID: "openclaw", roots: roots,
                             includeFile: { $0.lastPathComponent == "openclaw-agent.sqlite" },
                             parse: OpenClawSessionParser.database, useDiscoveredPathForParser: true)
    }

    static func openClawRoots(environment: EnvironmentReading, home: URL) -> [URL] {
        let base = configured("OPENCLAW_HOME", environment: environment, home: home) ?? home
        if let state = configured("OPENCLAW_STATE_DIR", environment: environment, home: base) {
            return ["agents", "sessions"].map { state.appendingPathComponent($0) }
        }
        if let profile = environment.value(for: "OPENCLAW_PROFILE")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           profile.lowercased() != "default", profile.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$", options: .regularExpression) != nil {
            return ["agents", "sessions"].map { base.appendingPathComponent(".openclaw-\(profile)/" + $0) }
        }
        return [".openclaw", ".clawdbot", ".moltbot", ".moldbot"].flatMap { state in
            ["agents", "sessions"].map { base.appendingPathComponent(state + "/" + $0) }
        }
    }

    static func configured(_ key: String, environment: EnvironmentReading, home: URL) -> URL? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if key == "OPENCLAW_HOME", value == "undefined" || value == "null" { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value)
    }
}
