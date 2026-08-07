import Foundation

/// Runs a family's official login CLI (`claude auth login`, `codex login`) pinned to one home —
/// a profile's Sign-In Workspace, or the Shared Runtime Home for the very first account. The child
/// gets the parent environment minus every provider auth override, so an exported API key or token
/// can never masquerade as the account being signed in. This launcher exists only for official
/// login flows; it never starts a normal session in a workspace.
struct AccountSignInLauncher: Sendable {
    init() {}

    /// Claude variables that override the stored subscription login when present. Removed from the
    /// login child only — the parent shell is never modified.
    static let claudeAuthEnvironmentRemovals = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_SCOPES",
    ]

    /// Codex environment credentials take precedence over a persisted ChatGPT login, so they are
    /// removed from the login child for the same reason.
    static let codexAuthEnvironmentRemovals = [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
    ]

    /// Codex logins must land in a file `auth.json`: a keyring credential is not scoped by
    /// `CODEX_HOME` under a documented contract, so allowing it would blur which account a
    /// workspace holds.
    static let codexFileCredentialStoreArguments = [
        "-c",
        "cli_auth_credentials_store=\"file\"",
    ]

    static func loginArguments(family: String) -> [String] {
        switch family {
        case "claude": ["auth", "login"]
        case "codex": codexFileCredentialStoreArguments + ["login"]
        default: []
        }
    }

    /// The login child's environment: auth overrides removed, the family's home variable pinned.
    static func loginEnvironment(
        family: String,
        home: String,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        switch family {
        case "claude":
            for key in claudeAuthEnvironmentRemovals { environment.removeValue(forKey: key) }
            environment["CLAUDE_CONFIG_DIR"] = home
        case "codex":
            for key in codexAuthEnvironmentRemovals { environment.removeValue(forKey: key) }
            environment["CODEX_HOME"] = home
        default:
            break
        }
        return environment
    }

    /// Spawns the official login and returns its exit status. Cancellation terminates the child.
    /// Output is discarded — the login speaks through the browser it opens, and its stdout can
    /// carry account details that must not reach our logs. `usesLoginShellPATH` matters for the
    /// packaged app: a Finder/Dock launch inherits only launchd's PATH, which doesn't contain
    /// `~/.local/bin`, Homebrew, or npm prefixes — the very places `claude`/`codex` live — so the
    /// login-shell capture's PATH is applied before resolving the executable.
    func runLogin(
        family: String,
        home: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        usesLoginShellPATH: Bool = true
    ) async throws -> Int32 {
        var environment = Self.loginEnvironment(family: family, home: home, base: baseEnvironment)
        if usesLoginShellPATH,
           let shellPATH = LoginShellEnvironment.shared.value(for: "PATH")?.nilIfEmpty {
            environment["PATH"] = shellPATH
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [family] + Self.loginArguments(family: family)
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        AppLog.debug(.subprocess, "account sign-in launch \(family) login")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { child in
                    if child.terminationReason == .uncaughtSignal {
                        continuation.resume(returning: 128 + child.terminationStatus)
                    } else {
                        continuation.resume(returning: child.terminationStatus)
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            // terminate() on a never-launched Process raises; cancellation can beat run().
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
