import Darwin
import Foundation

enum AccountShellProfile: String, CaseIterable, Identifiable {
    case zsh
    case fish

    var id: String { rawValue }

    var title: String { rawValue }

    /// 첫 전환 확정 시 설치되는 static wrapper — family의 auth 환경 override 제거, Shared Runtime Home 고정, 실제 도구 실행.
    /// 선택 profile 미참조 — 전환의 실체는 shared home의 교체된 인증이므로 wrapper는 활성 계정을 알 필요 없음.
    func setupSource(family: String, configurationHome: String) -> String {
        let removals = (family == "claude"
            ? AccountSignInLauncher.claudeAuthEnvironmentRemovals
            : AccountSignInLauncher.codexAuthEnvironmentRemovals
        )
        .map { "-u \($0)" }
        .joined(separator: " ")
        let assignment = family == "claude" ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        let arguments = family == "codex" ? " -c 'cli_auth_credentials_store=\"file\"'" : ""
        let home = Self.shellQuoted(configurationHome)

        switch self {
        case .zsh:
            return """
            # >>> OpenUsage \(family) account switching >>>
            unalias \(family) 2>/dev/null
            function \(family) {
              env \(removals) \(assignment)=\(home) command \(family)\(arguments) "$@"
            }
            # <<< OpenUsage \(family) account switching <<<
            """
        case .fish:
            return """
            # >>> OpenUsage \(family) account switching >>>
            functions -e \(family) 2>/dev/null
            function \(family)
              env \(removals) \(assignment)=\(home) command \(family)\(arguments) $argv
            end
            # <<< OpenUsage \(family) account switching <<<
            """
        }
    }

    fileprivate static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum AccountShellInstaller {
    static func defaultShell() -> AccountShellProfile? {
        guard let entry = getpwuid(getuid()) else { return nil }
        let path = String(cString: entry.pointee.pw_shell)
        return AccountShellProfile(rawValue: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// shell profile에 family marker 블록 설치·갱신 — idempotent, 기존 OpenUsage 블록은 제자리 교체·나머지 내용 보존.
    static func install(
        family: String,
        shell: AccountShellProfile,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let home = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        let configurationHome = sharedConfigurationHome(family: family, homeDirectory: home)
        let source = shell.setupSource(family: family, configurationHome: configurationHome)
        switch shell {
        case .zsh:
            try replace(source, for: family, at: home.appendingPathComponent(".zshrc"), fileManager: fileManager)
        case .fish:
            let config = home.appendingPathComponent(".config/fish/config.fish")
            try fileManager.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(source, for: family, at: config, fileManager: fileManager)
        }
    }

    static func sharedConfigurationHome(family: String, homeDirectory: URL) -> String {
        homeDirectory.appendingPathComponent(".\(family)").path
    }

    private static func replace(_ source: String, for family: String, at url: URL, fileManager: FileManager) throws {
        // rc 파일이 symlink일 수 있음 — 해석 후 실제 파일에 기록해 링크 보존.
        let url = fileManager.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath() : url
        let start = "# >>> OpenUsage \(family) account switching >>>"
        let end = "# <<< OpenUsage \(family) account switching <<<"
        let existing = fileManager.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8)
            : ""
        var updated = existing
        if let startRange = existing.range(of: start),
           let endRange = existing.range(of: end, range: startRange.lowerBound..<existing.endIndex) {
            let rangeEnd = existing[endRange.upperBound...].firstIndex(of: "\n")
                .map { existing.index(after: $0) } ?? endRange.upperBound
            updated.removeSubrange(startRange.lowerBound..<rangeEnd)
        }
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated += "\n"
        }
        updated += source + "\n"
        try Data(updated.utf8).write(to: url, options: .atomic)
    }
}
