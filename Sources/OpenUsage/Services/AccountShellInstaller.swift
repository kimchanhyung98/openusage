import Darwin
import Foundation

enum AccountShellProfile: String, CaseIterable, Identifiable {
    case zsh
    case fish

    var id: String { rawValue }

    var title: String { rawValue }

    /// The static wrapper installed on the first confirmed switch: strip the family's auth
    /// environment overrides, pin the Shared Runtime Home, run the real tool. It never reads the
    /// selected profile — the switch's substance is the shared home's replaced authentication, so
    /// the wrapper doesn't need to know which account is active.
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

    /// Installs or refreshes the family's marker block in the shell profile. Idempotent: an
    /// existing OpenUsage block is replaced in place, everything else in the file is preserved.
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
        // The rc file may be a symlink into a dotfiles repo; the atomic write below would replace
        // the link itself with a regular file, so resolve it and write to the real file.
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
