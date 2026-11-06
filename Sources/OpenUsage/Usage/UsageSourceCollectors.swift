import Foundation

/// 추가 도구의 저장 위치와 수집기 구성. 기존 원장과 계정 API는 각 프로바이더에서 관리.
enum UsageSourceCollectors {
    static func make(environment: EnvironmentReading, home: URL) -> [any UsageCollecting] {
        let geminiHome = configured("GEMINI_CLI_HOME", environment: environment, home: home) ?? home
        let qwen = configured("QWEN_RUNTIME_DIR", environment: environment, home: home)
            ?? configured("QWEN_HOME", environment: environment, home: home) ?? home.appendingPathComponent(".qwen")
        return [
            PiUsageScanner(environment: environment, homeDirectory: { home }),
            UsageFileCollector(
                sourceID: "gemini", providerID: "gemini", roots: [
                    geminiHome.appendingPathComponent(".gemini/tmp"), geminiHome.appendingPathComponent(".cache/.gemini/tmp")
                ], version: 3, includeFile: { $0.path.contains("/chats/") && ["json", "jsonl"].contains($0.pathExtension) },
                parse: GeminiSessionParser.parse
            ),
            qwenCollector(root: qwen)
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

    static func configured(_ key: String, environment: EnvironmentReading, home: URL) -> URL? {
        guard let value = environment.value(for: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        if value == "~" { return home }
        if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2))) }
        return URL(fileURLWithPath: value)
    }
}
