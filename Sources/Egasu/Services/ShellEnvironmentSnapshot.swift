import Foundation

/// identity 해석이 의존하는 login-shell 사실(provider home override·OAuth endpoint 스위치) — 성공한 shell 캡처마다 영속화.
/// `ProcessEnvironmentReader`가 세션 내내 이 키를 persisted 사실에 고정 — 느린 shell이 export된 override를 "미설정"으로 오독하는 일 방지, 변경된 export는 다음 launch부터 적용.
struct ShellEnvironmentSnapshot: Codable, Equatable, Sendable {
    /// identity 관련 non-secret 설정 변수 — secret(API 키·token) 추가 금지, snapshot은 UserDefaults에 평문 저장.
    static let capturedKeys = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "KIMI_CODE_HOME", "XDG_CONFIG_HOME",
        "USER_TYPE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
        "CLAUDE_LOCAL_OAUTH_API_BASE", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
        "KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST",
        "KIMI_DISABLE_OAUTH_LOCK",
    ]

    /// Kimi identity 설정 추가 전 v1 snapshot format의 키.
    static let legacyCapturedKeys = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME",
        "USER_TYPE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
        "CLAUDE_LOCAL_OAUTH_API_BASE", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
    ]

    /// 캡처된 값 — pinned 키의 부재는 캡처 시점 "미export 검증됨", 프로세스 수명 동안 "override 없음"으로 read.
    var values: [String: String]
    var capturedAt: Date
    var pinnedKeys: Set<String>

    init(
        values: [String: String],
        capturedAt: Date,
        pinnedKeys: Set<String> = Set(Self.capturedKeys)
    ) {
        self.values = values
        self.capturedAt = capturedAt
        self.pinnedKeys = pinnedKeys
    }

    private enum CodingKeys: String, CodingKey {
        case values
        case capturedAt
        case pinnedKeys
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        values = try container.decode([String: String].self, forKey: .values)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        pinnedKeys = try container.decodeIfPresent(Set<String>.self, forKey: .pinnedKeys)
            ?? Set(Self.capturedKeys)
    }

    /// warm login-shell 레이어 기준 캡처 키 전체 값 — 캡처 실패 시 `nil`.
    /// 빈 캡처는 spawn/parse 실패 — 그 "사실"의 영속화 금지.
    static func current(
        shellEnvironment: LoginShellEnvironment = .shared,
        capturedAt: Date = Date()
    ) -> ShellEnvironmentSnapshot? {
        guard shellEnvironment.capturedSuccessfully else { return nil }
        var values: [String: String] = [:]
        for key in capturedKeys {
            if let value = shellEnvironment.value(for: key) { values[key] = value }
        }
        return ShellEnvironmentSnapshot(values: values, capturedAt: capturedAt)
    }
}

/// snapshot의 UserDefaults 영속화 (`openusage.shellEnvSnapshot.v2`) — post-launch refresh task의 actor 간 이동용 class, UserDefaults 자체는 thread-safe.
final class ShellEnvironmentSnapshotStore: @unchecked Sendable {
    static let storageKey = "openusage.shellEnvSnapshot.v2"
    static let previousStorageKey = "openusage.shellEnvSnapshot.v1"

    /// 프로세스 시작 시점 snapshot — 1회 decode·memoize(`static let`은 thread-safe lazy), identity-key read마다 UserDefaults 재조회 금지.
    /// 프로세스 수명 동안 의도적 동결 — 이 동결이 곧 세션 pin; refresh task의 새 사실은 다음 launch부터 적용.
    static let launchSnapshot: ShellEnvironmentSnapshot? =
        ShellEnvironmentSnapshotStore(defaults: .standard).load()

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> ShellEnvironmentSnapshot? {
        if let data = defaults.data(forKey: Self.storageKey) {
            guard let snapshot = try? JSONDecoder().decode(ShellEnvironmentSnapshot.self, from: data) else {
                AppLog.warn(.config, "shell-environment snapshot was undecodable; discarding it")
                defaults.removeObject(forKey: Self.storageKey)
                return nil
            }
            return snapshot
        }

        guard let data = defaults.data(forKey: Self.previousStorageKey) else { return nil }
        guard let previous = try? JSONDecoder().decode(ShellEnvironmentSnapshot.self, from: data) else {
            AppLog.warn(.config, "legacy shell-environment snapshot was undecodable; discarding it")
            defaults.removeObject(forKey: Self.previousStorageKey)
            return nil
        }

        let migrated = ShellEnvironmentSnapshot(
            values: previous.values,
            capturedAt: previous.capturedAt,
            pinnedKeys: Set(ShellEnvironmentSnapshot.legacyCapturedKeys)
        )
        save(migrated)
        return migrated
    }

    func save(_ snapshot: ShellEnvironmentSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            AppLog.error(.config, "failed to encode shell-environment snapshot; keeping the previous one")
            return
        }
        defaults.set(data, forKey: Self.storageKey)
        defaults.removeObject(forKey: Self.previousStorageKey)
    }

    /// `prewarm()`이 시작한 login-shell 캡처를 off-main에서 대기(캡처 자체 timeout 한도) 후 최신 snapshot 영속화.
    /// 캡처 실패 시 영속화 없음 — 이전 snapshot 사실 유지. caller가 task 보유, teardown 시 취소.
    func startRefreshTask(shellEnvironment: LoginShellEnvironment = .shared) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            guard shellEnvironment.ensureCaptured(),
                  let snapshot = ShellEnvironmentSnapshot.current(shellEnvironment: shellEnvironment)
            else {
                AppLog.warn(.config, "login-shell capture failed; keeping the previous shell-environment snapshot")
                return
            }
            let previous = load()
            save(snapshot)
            if let previous, previous.values != snapshot.values {
                AppLog.info(.config, "shell-environment snapshot changed since the last capture; launch-time readers pick it up next launch")
            }
        }
    }
}
