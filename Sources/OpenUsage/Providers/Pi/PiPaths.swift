import Foundation

/// 실행 cwd가 필요한 프로젝트 설정·상대 sessionDir는 추정하지 않는 로컬 세션 경로 선택.
enum PiPaths {
    enum SettingsError: Error {
        case invalidSessionDirectory
        case relativeSessionDirectory
    }

    static func sessionsDirectory(
        environment: EnvironmentReading, homeDirectory: URL,
        files: TextFileAccessing = LocalTextFileAccessor()
    ) throws -> URL {
        if let override = environment.value(for: "PI_CODING_AGENT_SESSION_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard override.hasPrefix("/") || override == "~" || override.hasPrefix("~/") else {
                throw SettingsError.relativeSessionDirectory
            }
            return resolve(override, home: homeDirectory)
        }
        let configDir = environment.value(for: "PI_CODING_AGENT_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let agent = configDir.map { resolve($0, home: homeDirectory) }
            ?? homeDirectory.appendingPathComponent(".pi/agent")
        let fallback = agent.appendingPathComponent("sessions")
        guard let text = try files.readTextIfPresent(agent.appendingPathComponent("settings.json").path) else {
            return fallback
        }
        let settings = try UsageJSON.object(Data(text.utf8))
        guard let value = settings["sessionDir"] else { return fallback }
        guard let directory = value as? String else { throw SettingsError.invalidSessionDirectory }
        guard let directory = directory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return fallback
        }
        guard directory.hasPrefix("/") || directory == "~" || directory.hasPrefix("~/") else {
            throw SettingsError.relativeSessionDirectory
        }
        return resolve(directory, home: homeDirectory)
    }

    static func ompSessionsDirectory(environment: EnvironmentReading, homeDirectory: URL) -> URL? {
        let ompProfile: String?
        if let process = environment as? ProcessEnvironmentReader {
            // OMP는 빈 환경 변수도 기본 프로필 선택으로 취급.
            ompProfile = process.processEnvironment["OMP_PROFILE"]
                ?? process.shellEnvironment.environmentSnapshot()?["OMP_PROFILE"]
        } else {
            ompProfile = environment.value(for: "OMP_PROFILE")
        }
        guard let profile = normalizedProfile(ompProfile ?? environment.value(for: "PI_PROFILE")) else {
            return nil
        }
        let config = environment.value(for: "PI_CONFIG_DIR")?.nilIfEmpty ?? ".omp"
        let base = homeDirectory.appendingPathComponent(config)
        var root = base
        if !profile.isEmpty { root.appendPathComponent("profiles/" + profile) }
        let defaultAgent = root.appendingPathComponent("agent")
        var override = profile.isEmpty ? environment.value(for: "PI_CODING_AGENT_DIR")?.nilIfEmpty : nil
        if let legacy = normalizedProfile(environment.value(for: "PI_PROFILE")), !legacy.isEmpty,
           override == base.appendingPathComponent("profiles/" + legacy + "/agent").path {
            override = nil
        }
        let agent = override.map { resolve($0, home: homeDirectory) } ?? defaultAgent
        if agent.standardizedFileURL == defaultAgent.standardizedFileURL,
           let xdg = environment.value(for: "XDG_DATA_HOME")?.nilIfEmpty {
            var data = resolve(xdg, home: homeDirectory).appendingPathComponent("omp")
            if !profile.isEmpty { data.appendPathComponent("profiles/" + profile) }
            if FileManager.default.fileExists(atPath: data.path) { return data.appendingPathComponent("sessions") }
        }
        return agent.appendingPathComponent("sessions")
    }

    private static func normalizedProfile(_ value: String?) -> String? {
        let profile = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if profile.isEmpty || profile == "default" { return "" }
        guard profile.range(of: "^[a-z0-9][a-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              !profile.hasSuffix("."),
              profile.range(of: "^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\\..*)?$", options: [.regularExpression, .caseInsensitive]) == nil
        else { return nil }
        return profile
    }

    private static func resolve(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }
}
