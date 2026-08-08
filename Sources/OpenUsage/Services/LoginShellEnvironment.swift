import Foundation

/// login shell 환경 1회 캡처·캐시 — Finder/Dock/`open` launch GUI 앱은 launchd 세션 환경만 상속하므로 shell profile export를 여기서 해석.
/// `ProcessEnvironmentReader`가 process 환경 다음 fallback으로 사용.
/// 스레딩 계약: 캡처 subprocess는 lock 보유 중 실행·대기 금지; 메인 스레드는 캐시만 read(미완 시 `nil`), off-main caller만 on-demand 캡처.
final class LoginShellEnvironment: @unchecked Sendable {
    static let shared = LoginShellEnvironment()

    /// `env` 출력을 감싸는 sentinel token — login shell의 banner/MOTD를 변수로 오파싱하지 않고 폐기.
    private static let beginMarker = "__OPENUSAGE_ENV_BEGIN__"
    private static let endMarker = "__OPENUSAGE_ENV_END__"
    /// shell spawn 시간 제한 — 느리거나 hang된 profile의 provider refresh 무한 정지 방지.
    private static let captureTimeout: TimeInterval = 5

    private let runner: ProcessRunning
    /// `cached` 전용 guard — 마이크로초 단위 보유, subprocess 동안 보유 금지.
    private let stateLock = NSLock()
    /// 캡처 직렬화 — 동시 caller에도 subprocess 1개. off-main에서만 획득 — UI 스레드 대기 불가.
    private let captureLock = NSLock()
    private var cached: [String: String]?

    init(runner: ProcessRunning = SystemProcessRunner()) {
        self.runner = runner
    }

    /// 캡처된 login-shell 값 — 부재·빈 값은 `nil`.
    /// 메인 스레드는 캐시만 read(prewarm 전 `nil`), off-main은 on-demand 캡처 — subprocess로 메인 스레드 blocking 금지.
    func value(for name: String) -> String? {
        if let env = cachedSnapshot() { return env[name]?.nilIfEmpty }
        guard !Thread.isMainThread else { return nil }
        return capturedEnvironment()[name]?.nilIfEmpty
    }

    /// launch 시 off-main 캡처 선행 — 첫 provider refresh·UI read가 warm 캐시를 만나도록. 중복 호출 안전.
    /// `.userInitiated` 필수 — utility 우선순위는 cold-launch 경쟁에서 첫 refresh에 밀려 shell export를 부재로 오판.
    func prewarm() {
        Task.detached(priority: .userInitiated) { [weak self] in
            _ = self?.capturedEnvironment()
        }
    }

    /// 캡처 완료 및 유효 환경 여부 — 실제 login shell은 최소 `PATH`/`HOME` export, 빈 캡처는 spawn/parse 실패.
    /// 빈 캡처에서 파생된 사실("override 미export" 등) 영속화 금지.
    var capturedSuccessfully: Bool {
        !(cachedSnapshot() ?? [:]).isEmpty
    }

    /// off-main 전용 — 1회 캡처 실행 보장(prewarm 미완 시 즉시 spawn) 후 성공 여부 보고.
    func ensureCaptured() -> Bool {
        guard !Thread.isMainThread else { return capturedSuccessfully }
        _ = capturedEnvironment()
        return capturedSuccessfully
    }

    private func cachedSnapshot() -> [String: String]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cached
    }

    /// 환경 1회 캡처 후 캐시 — off-main 전용, `captureLock`으로 subprocess 1개 보장.
    /// spawn은 lock 미보유 상태 실행, 저장만 짧은 `stateLock` — 동시 캐시 read의 subprocess 대기 금지.
    private func capturedEnvironment() -> [String: String] {
        captureLock.lock()
        defer { captureLock.unlock() }
        if let env = cachedSnapshot() { return env }
        let captured = capture()
        stateLock.lock()
        cached = captured
        stateLock.unlock()
        return captured
    }

    private func capture() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.nilIfEmpty ?? "/bin/zsh"
        // `-i -l -c`: rc 파일과 profile 파일 모두 source; `env -0`은 NUL 구분 `KEY=VALUE`로 개행 포함 값에 안전.
        let command = "printf '%s\\0' \(Self.beginMarker); /usr/bin/env -0; printf '%s\\0' \(Self.endMarker)"
        do {
            let result = try runner.run(
                executable: shell,
                arguments: ["-ilc", command],
                environment: [:],
                timeout: Self.captureTimeout
            )
            guard result.succeeded else {
                AppLog.warn(.subprocess, "login-shell env capture exited \(result.exitCode)")
                return [:]
            }
            return Self.parse(result.stdout)
        } catch {
            AppLog.warn(.subprocess, "login-shell env capture failed: \(error.localizedDescription)")
            return [:]
        }
    }

    /// NUL 구분 `env -0` 출력 파싱 — begin/end marker 사이 `KEY=VALUE`만 유지, 밖의 shell banner 무시.
    static func parse(_ output: String) -> [String: String] {
        let tokens = output.components(separatedBy: "\0")
        guard let begin = tokens.firstIndex(of: beginMarker) else { return [:] }
        let end = tokens.firstIndex(of: endMarker) ?? tokens.count
        guard begin < end else { return [:] }

        var environment: [String: String] = [:]
        for token in tokens[(begin + 1)..<end] {
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separator])
            guard !key.isEmpty else { continue }
            environment[key] = String(token[token.index(after: separator)...])
        }
        return environment
    }
}
