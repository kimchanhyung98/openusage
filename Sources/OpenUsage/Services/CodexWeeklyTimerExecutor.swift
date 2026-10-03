import Foundation

struct CodexWeeklyTimerExecutionResult: Sendable {
    var launched: Bool
    var completed: Bool
    var updatedAuth: CodexAuth?
    var failureDescription: String?
    var verificationCanClearFailure = true
}

@MainActor
protocol CodexWeeklyTimerExecuting {
    func execute(
        auth: CodexAuth,
        canLaunch: @escaping @MainActor () async -> Bool
    ) async -> CodexWeeklyTimerExecutionResult
}

extension CodexWeeklyTimerExecuting {
    func execute(auth: CodexAuth) async -> CodexWeeklyTimerExecutionResult {
        await execute(auth: auth, canLaunch: { true })
    }
}

/// 계정 인증을 임시 CLI 홈에만 제공, 모델 답변은 저장·로그·타이머 계산에 사용 금지.
@MainActor
final class CodexWeeklyTimerExecutor: CodexWeeklyTimerExecuting {
    static let prompt = "When does my weekly Codex usage limit reset? Answer briefly without using tools."
    static let configuration = [
        "cli_auth_credentials_store=\"file\"",
        "model_provider=\"openai\"",
        "approval_policy=\"never\"",
        "web_search=\"disabled\"",
        "project_doc_max_bytes=0",
        "mcp_servers={}",
        "plugins={}",
        "skills.include_instructions=false",
        "skills.bundled.enabled=false",
        "tools.update_plan.enabled=false",
        "tools.experimental_request_user_input.enabled=false",
        "memories.generate_memories=false",
        "memories.use_memories=false",
        "apps._default.enabled=false",
        "history.persistence=\"none\"",
        "analytics.enabled=false",
        "features.skip_host_skill_discovery=true",
    ] + [
        "shell_tool", "unified_exec", "shell_snapshot", "apps", "browser_use", "computer_use",
        "image_generation", "view_image", "hooks", "memories", "multi_agent", "multi_agent_v2",
        "plugins", "remote_plugin", "recommended_plugins", "goals", "sleep_tool", "code_mode",
        "code_mode_host", "skill_search", "skill_mcp_dependency_install", "workspace_dependencies",
        "daemon_auto_start", "auth_elicitation", "realtime_conversation", "in_app_local_automation",
        "tool_suggest",
    ].map { "features.\($0)=false" }

    private let processRunner: any StreamingProcessRunning
    private let executableResolver: @MainActor () -> URL?
    private let baseDirectory: URL
    private let timeout: TimeInterval

    init(
        processRunner: any StreamingProcessRunning = StreamingProcessRunner(),
        executableResolver: @escaping @MainActor () -> URL? = CodexWeeklyTimerExecutor.resolveExecutable,
        baseDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUsage.CodexWeeklyTimer", isDirectory: true),
        timeout: TimeInterval = 60
    ) {
        self.processRunner = processRunner
        self.executableResolver = executableResolver
        self.baseDirectory = baseDirectory
        self.timeout = timeout
        do {
            try CodexWeeklyTimerWorkspace.cleanAbandonedWorkspaces(baseDirectory: baseDirectory)
        } catch {
            AppLog.error(.subprocess, "Codex weekly timer abandoned credential cleanup failed")
        }
    }

    func execute(
        auth: CodexAuth,
        canLaunch: @escaping @MainActor () async -> Bool
    ) async -> CodexWeeklyTimerExecutionResult {
        guard !Task.isCancelled else { return failure("Codex weekly timer message was cancelled.") }
        guard auth.tokens?.accessToken?.isEmpty == false,
              auth.tokens?.refreshToken?.isEmpty == false,
              auth.tokens?.idToken?.isEmpty == false else {
            return failure("Codex weekly timer requires a ChatGPT subscription login.")
        }
        guard let executableURL = executableResolver(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return failure("Codex CLI could not be found for the weekly timer message.")
        }
        let workspace: CodexWeeklyTimerWorkspace
        do {
            workspace = try CodexWeeklyTimerWorkspace(baseDirectory: baseDirectory)
        } catch {
            return failure("Codex weekly timer credentials could not be prepared.")
        }
        var result: CodexWeeklyTimerExecutionResult
        var isolatedAuth = auth
        isolatedAuth.apiKey = nil
        do {
            try await verifyCapabilities(executableURL: executableURL, workspace: workspace)
            try workspace.writeAuth(isolatedAuth)
            try Task.checkCancellation()
            result = await runMessage(executableURL: executableURL, workspace: workspace, canLaunch: canLaunch)
            do {
                var latestAuth = try workspace.readAuth()
                if latestAuth != isolatedAuth {
                    latestAuth.apiKey = auth.apiKey
                    result.updatedAuth = latestAuth
                }
            } catch {
                result.verificationCanClearFailure = false
                result.failureDescription = result.failureDescription
                    ?? "Codex weekly timer credentials could not be read after the message."
                AppLog.error(.subprocess, "Codex weekly timer credentials could not be read after the message.")
            }
        } catch is CancellationError {
            result = failure("Codex weekly timer message was cancelled.")
        } catch {
            result = failure("This Codex CLI could not prepare an isolated weekly timer message. Update Codex and try again.")
        }
        do {
            try workspace.remove()
        } catch {
            result.verificationCanClearFailure = false
            result.failureDescription = "Codex weekly timer temporary credentials could not be removed."
            AppLog.error(.subprocess, "Codex weekly timer temporary credential cleanup failed")
        }
        return result
    }

    private func verifyCapabilities(executableURL: URL, workspace: CodexWeeklyTimerWorkspace) async throws {
        let help = try await processRunner.run(request(
            executableURL: executableURL, workspace: workspace,
            arguments: ["exec", "--help"], timeout: 5, outputLimit: 32_768
        ))
        guard help.exitCode == 0,
              ["--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check"]
                .allSatisfy({ help.output.contains($0) }) else {
            throw CapabilityError.unsupported
        }
        // 엄격한 파싱으로 버전별 옵션 호환성 확인, 모델 요청·인증 로드는 없는 명령만 사용.
        let config = try await processRunner.run(request(
            executableURL: executableURL, workspace: workspace,
            arguments: ["app-server", "--strict-config", "--stdio"] + Self.configurationArguments,
            timeout: 5, outputLimit: 0
        ))
        guard config.exitCode == 0 else { throw CapabilityError.unsupported }
    }

    private func runMessage(
        executableURL: URL, workspace: CodexWeeklyTimerWorkspace,
        canLaunch: @escaping @MainActor () async -> Bool
    ) async -> CodexWeeklyTimerExecutionResult {
        let events = CodexWeeklyTimerEvents()
        let arguments = [
            "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--sandbox", "read-only", "--skip-git-repo-check", "--color", "never",
        ] + Self.configurationArguments + ["-"]
        let request = request(
            executableURL: executableURL, workspace: workspace, arguments: arguments,
            standardInput: Data((Self.prompt + "\n").utf8), timeout: timeout, outputLimit: 0
        )
        let stop = CodexWeeklyTimerStopSignal()
        let task = Task<StreamingProcessResult?, Error> { [processRunner] in
            guard !Task.isCancelled, await canLaunch(), !Task.isCancelled else { return nil }
            return try await processRunner.run(request, onLaunch: { stop.didLaunch() }, onOutput: { chunk in
                if events.append(chunk) { stop.cancel() }
            })
        }
        stop.install { task.cancel() }
        do {
            let stopped = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard let stopped else {
                return failure("Codex weekly timer account changed before the message started.")
            }
            let completed = stopped.exitCode == 0 && events.completed
            return CodexWeeklyTimerExecutionResult(
                launched: true, completed: completed, updatedAuth: nil,
                failureDescription: completed ? nil : "Codex weekly timer message did not complete."
            )
        } catch is CancellationError {
            return failure(events.rejectedOutput
                ? "Codex weekly timer stopped an unexpected tool or invalid response."
                : "Codex weekly timer message was cancelled.", launched: stop.hasLaunched)
        } catch StreamingProcessRunnerError.timedOut {
            return failure("Codex weekly timer message timed out.", launched: stop.hasLaunched)
        } catch {
            return failure("Codex weekly timer message failed.", launched: stop.hasLaunched)
        }
    }

    private func request(
        executableURL: URL, workspace: CodexWeeklyTimerWorkspace,
        arguments: [String], standardInput: Data = Data(), timeout: TimeInterval, outputLimit: Int
    ) -> StreamingProcessRequest {
        StreamingProcessRequest(
            executableURL: executableURL, arguments: arguments,
            environment: workspace.environment(executableURL: executableURL),
            currentDirectoryURL: workspace.workingDirectory, standardInput: standardInput,
            timeout: timeout, outputLimit: outputLimit, captureStandardErrorSeparately: true
        )
    }

    private func failure(_ description: String, launched: Bool = false) -> CodexWeeklyTimerExecutionResult {
        CodexWeeklyTimerExecutionResult(
            launched: launched, completed: false, updatedAuth: nil, failureDescription: description
        )
    }

    private static var configurationArguments: [String] {
        configuration.flatMap { ["-c", $0] }
    }

    private static func resolveExecutable() -> URL? {
        let path = LoginShellEnvironment.shared.value(for: "PATH")
            ?? ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for component in path.split(separator: ":") where component.hasPrefix("/") {
            let url = URL(fileURLWithPath: String(component), isDirectory: true).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private enum CapabilityError: Error { case unsupported }
}

/// JSONL 이벤트의 종류만 보존, stdout 크기·줄 길이를 제한하여 응답 본문 축적 방지.
final class CodexWeeklyTimerEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var turnCompleted = false
    private var failed = false
    private var rejected = false

    @discardableResult
    func append(_ chunk: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !rejected else { return true }
        let fragments = chunk.split(separator: "\n", omittingEmptySubsequences: false)
        for fragment in fragments.dropLast() {
            pending += fragment
            consumeLine()
            pending = ""
        }
        pending += fragments.last ?? ""
        if pending.utf8.count > 262_144 {
            failed = true
            rejected = true
            pending = ""
        }
        return rejected
    }

    var rejectedOutput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    var completed: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { consumeLine(); pending = "" }
        return turnCompleted && !failed
    }

    private func consumeLine() {
        guard !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard pending.utf8.count <= 262_144,
              let event = try? JSONSerialization.jsonObject(with: Data(pending.utf8)) as? [String: Any],
              let type = event["type"] as? String else {
            failed = true
            rejected = true
            return
        }
        // CLI 시작 경고도 error 항목으로 전달 — 요청 실패는 최상위 error·turn.failed·종료 코드로 판정.
        if type.hasPrefix("item."),
           let item = event["item"] as? [String: Any],
           let itemType = item["type"] as? String,
           !["reasoning", "agent_message", "error"].contains(itemType) {
            failed = true
            rejected = true
        }
        if type == "turn.completed" { turnCompleted = true }
        if type == "turn.failed" || type == "error" { failed = true }
    }
}

private final class CodexWeeklyTimerStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    private var stopped = false
    private var launched = false

    var hasLaunched: Bool { lock.withLock { launched } }

    func didLaunch() { lock.withLock { launched = true } }

    func install(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        let stopped = stopped
        lock.unlock()
        if stopped { action() }
    }

    func cancel() {
        lock.lock()
        stopped = true
        let action = action
        lock.unlock()
        action?()
    }
}
