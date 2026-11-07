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
        let data = configured("XDG_DATA_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".local/share")
        let kiloData = data.appendingPathComponent("kilo")
        let kiloOverride = environment.value(for: "KILO_DB")?.nilIfEmpty
        let kiloFile = kiloOverride.map { raw in
            (raw.hasPrefix("/") ? URL(fileURLWithPath: raw) : kiloData.appendingPathComponent(raw)).resolvingSymlinksInPath()
        }
        let kiloRoots = kiloOverride == ":memory:" ? [] : [kiloFile ?? kiloData]
        let legacyKilo = ["Code", "Code - Insiders", "Cursor", "VSCodium"].map {
            home.appendingPathComponent("Library/Application Support/\($0)/User/globalStorage/kilocode.kilo-code/tasks")
        } + [home.appendingPathComponent(".vscode-server/data/User/globalStorage/kilocode.kilo-code/tasks")]
        var sources: [any UsageCollecting] = [
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
                               includeFile: DeepSeekSessionParser.isCurrentGeneration, parse: DeepSeekSessionParser.parse),
            UsageSQLiteCollector(sourceID: "kilo", roots: kiloRoots, includeFile: { url in
                if let kiloFile { return url.resolvingSymlinksInPath() == kiloFile }
                let name = url.lastPathComponent
                guard url.pathExtension == "db" else { return false }
                if name == "kilo.db" || name.hasPrefix("kilo-") { return true }
                guard name.hasPrefix("opencode-") else { return false }
                let replacement = "kilo-" + name.dropFirst("opencode-".count)
                return !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(replacement).path)
            }, parse: KiloUsageParser.database),
            UsageFileCollector(sourceID: "kilocode", roots: legacyKilo, version: 2,
                               includeFile: { $0.lastPathComponent == "ui_messages.json" }, parse: KiloUsageParser.legacy),
            junieCollector(environment: environment, home: home),
            devinDesktop(home: home),
            kimiWork(home: home),
            kimiLegacy(environment: environment, home: home)
        ]
        sources += kiroLegacy(home: home)
        return sources
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

    static func junieCollector(
        environment: EnvironmentReading, home: URL, scanner: IncrementalJSONLScanner<UsageRecord>? = nil
    ) -> JunieUsageCollector {
        let root = configured("JUNIE_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".junie")
        return JunieUsageCollector(root: root.appendingPathComponent("sessions"), scanner: scanner)
    }

    static func devinDesktop(home: URL) -> UsageFileCollector {
        UsageFileCollector(sourceID: "devin-desktop", providerID: "devin",
                           roots: [home.appendingPathComponent("Library/Application Support/Devin/User/acp-events")], version: 4,
                           includeFile: { $0.pathExtension == "ndjson" }, parse: DevinDesktopParser.parse)
    }

    static func kimiWork(home: URL, scanner: IncrementalJSONLScanner<UsageRecord>? = nil) -> UsageFileCollector {
        let root = home.appendingPathComponent(
            "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions"
        )
        return UsageFileCollector(sourceID: "kimi-work", providerID: "kimi", roots: [root], version: 4, scanner: scanner,
                                  includeFile: { url in
            let prefix = root.resolvingSymlinksInPath().path + "/"
            let path = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).path
            guard path.hasPrefix(prefix) else { return false }
            let parts = path.dropFirst(prefix.count).split(separator: "/")
            return parts.count == 5 && parts[2] == "agents" && parts[4] == "wire.jsonl"
        }, parse: { data, path in try KimiSupplementParser.parse(data, path: path, work: true) })
    }

    static func kimiLegacy(environment: EnvironmentReading, home: URL) -> UsageFileCollector {
        let root = configured("KIMI_SHARE_DIR", environment: environment, home: home) ?? home.appendingPathComponent(".kimi")
        return UsageFileCollector(sourceID: "kimi-cli", providerID: "kimi-cli", roots: [root.appendingPathComponent("sessions")], version: 3,
                                  includeFile: { $0.lastPathComponent == "wire.jsonl" },
                                  parse: { data, path in try KimiSupplementParser.parse(data, path: path, work: false) })
    }

    static func kiroLegacy(home: URL) -> [any UsageCollecting] {
        [
            UsageFileCollector(sourceID: "kiro-cli", providerID: "kiro", roots: [home.appendingPathComponent(".kiro/sessions/cli")], version: 3,
                               includeFile: { $0.pathExtension == "json" }, parse: KiroLegacyUsageParser.session),
            UsageSQLiteCollector(sourceID: "kiro-cli", providerID: "kiro", roots: [
                home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3"),
                home.appendingPathComponent(".local/share/kiro-cli/data.sqlite3")
            ], includeFile: { $0.lastPathComponent == "data.sqlite3" }, parse: KiroLegacyUsageParser.database)
        ]
    }

    static func configured(_ key: String, environment: EnvironmentReading, home: URL) -> URL? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if key == "OPENCLAW_HOME", value == "undefined" || value == "null" { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value)
    }
}
