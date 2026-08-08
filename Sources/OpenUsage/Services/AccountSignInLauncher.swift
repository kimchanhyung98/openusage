import Foundation

/// family의 공식 로그인 CLI(`claude auth login`, `codex login`)를 한 home(Sign-In Workspace 또는 첫 계정의 Shared Runtime Home)에 고정해 실행.
/// child는 parent 환경에서 모든 provider auth override 제거 — export된 API 키·token의 로그인 계정 위장 금지. 공식 로그인 전용 — workspace의 일반 세션 시작 금지.
struct AccountSignInLauncher: Sendable {
    init() {}

    /// 존재 시 저장된 subscription 로그인을 override하는 Claude 변수 — 로그인 child에서만 제거, parent shell 불변.
    static let claudeAuthEnvironmentRemovals = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_SCOPES",
    ]

    /// Codex 환경 credential은 persisted ChatGPT 로그인보다 우선 — 같은 이유로 로그인 child에서 제거.
    static let codexAuthEnvironmentRemovals = [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
    ]

    /// Codex 로그인의 파일 `auth.json` 저장 강제 — keyring credential은 `CODEX_HOME` 스코프 계약이 없어 workspace 보유 계정을 모호하게 만듦.
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

    /// 로그인 child의 환경 — auth override 제거, family home 변수 고정.
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

    /// 공식 로그인 spawn 후 exit status 반환 — 취소 시 child 종료.
    /// 출력 폐기 — 로그인은 브라우저로 진행, stdout의 계정 상세가 로그에 유입 금지.
    /// `usesLoginShellPATH`: Finder/Dock launch는 launchd PATH만 상속(`~/.local/bin`·Homebrew·npm prefix 부재) — 실행 파일 해석 전 login-shell PATH 적용.
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
            // 미실행 Process의 terminate()는 예외 발생 — 취소가 run()보다 먼저일 수 있음.
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
