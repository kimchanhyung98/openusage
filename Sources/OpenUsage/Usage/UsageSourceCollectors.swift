import Foundation

/// 추가 도구의 저장 위치와 수집기 구성. 기존 원장과 계정 API는 각 프로바이더에서 관리.
enum UsageSourceCollectors {
    static func make(environment: EnvironmentReading, home: URL) -> [any UsageCollecting] {
        let geminiHome = configured("GEMINI_CLI_HOME", environment: environment, home: home) ?? home
        let qwen = configured("QWEN_RUNTIME_DIR", environment: environment, home: home)
            ?? configured("QWEN_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".qwen")
        let junieHome = environment.value(for: "JUNIE_HOME").map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".junie")
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
            UsageSQLiteCollector(sourceID: "kilo", roots: kiloRoots, includeFile: { url in
                if let kiloFile { return url.resolvingSymlinksInPath() == kiloFile }
                let name = url.lastPathComponent
                guard url.pathExtension == "db" else { return false }
                if name == "kilo.db" || name.hasPrefix("kilo-") { return true }
                guard name.hasPrefix("opencode-") else { return false }
                let replacement = "kilo-" + name.dropFirst("opencode-".count)
                return !FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(replacement).path)
            }, parse: KiloUsageParser.database),
            UsageFileCollector(sourceID: "kilocode", roots: legacyKilo,
                               includeFile: { $0.lastPathComponent == "ui_messages.json" }, parse: KiloUsageParser.legacy),
            JunieUsageCollector(root: junieHome.appendingPathComponent("sessions")),
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

    static func devinDesktop(home: URL) -> UsageFileCollector {
        UsageFileCollector(sourceID: "devin-desktop", providerID: "devin",
                           roots: [home.appendingPathComponent("Library/Application Support/Devin/User/acp-events")], version: 2,
                           includeFile: { $0.pathExtension == "ndjson" }, parse: DevinDesktopParser.parse)
    }

    static func kimiWork(home: URL) -> UsageFileCollector {
        UsageFileCollector(sourceID: "kimi-work", providerID: "kimi", roots: [home.appendingPathComponent(
            "Library/Application Support/kimi-desktop/daimon-share/daimon/runtime/kimi-code/home/sessions"
        )], version: 2, includeFile: { $0.lastPathComponent == "wire.jsonl" && $0.path.contains("/agents/") },
                           parse: { data, path in try KimiSupplementParser.parse(data, path: path, work: true) })
    }

    static func kimiLegacy(environment: EnvironmentReading, home: URL) -> UsageFileCollector {
        let root = configured("KIMI_SHARE_DIR", environment: environment, home: home) ?? home.appendingPathComponent(".kimi")
        return UsageFileCollector(sourceID: "kimi-cli", providerID: "kimi-cli", roots: [root.appendingPathComponent("sessions")], version: 2,
                                  includeFile: { $0.lastPathComponent == "wire.jsonl" },
                                  parse: { data, path in try KimiSupplementParser.parse(data, path: path, work: false) })
    }

    static func kiroLegacy(home: URL) -> [any UsageCollecting] {
        [
            UsageFileCollector(sourceID: "kiro-cli", providerID: "kiro", roots: [home.appendingPathComponent(".kiro/sessions/cli")], version: 2,
                               includeFile: { $0.pathExtension == "json" }, parse: KiroLegacyUsageParser.session),
            UsageSQLiteCollector(sourceID: "kiro-cli", providerID: "kiro", roots: [
                home.appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3"),
                home.appendingPathComponent(".local/share/kiro-cli/data.sqlite3")
            ], includeFile: { $0.lastPathComponent == "data.sqlite3" }, parse: KiroLegacyUsageParser.database)
        ]
    }

    static func configured(_ key: String, environment: EnvironmentReading, home: URL) -> URL? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value)
    }
}
