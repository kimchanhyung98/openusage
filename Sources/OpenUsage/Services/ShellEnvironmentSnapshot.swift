import Foundation

/// The login-shell facts identity resolution depends on (provider home overrides and OAuth endpoint
/// switches), persisted after every successful shell capture. Shell exports change ~never between
/// launches, so `ProcessEnvironmentReader` PINS these keys to the persisted facts for the whole
/// session: every reader sees the same values no matter when the async login-shell capture lands,
/// and a slow shell can't make an exported override read as "not set". A changed export applies
/// from the next launch. Only a genuinely first launch (no snapshot yet) has nothing to pin.
struct ShellEnvironmentSnapshot: Codable, Equatable, Sendable {
    /// Identity-relevant, non-secret configuration variables. Secrets (API keys, tokens) must never
    /// be added here — the snapshot lives in UserDefaults as plain text.
    static let capturedKeys = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "KIMI_CODE_HOME", "XDG_CONFIG_HOME",
        "USER_TYPE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
        "CLAUDE_LOCAL_OAUTH_API_BASE", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
        "KIMI_CODE_BASE_URL", "KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST",
        "KIMI_DISABLE_OAUTH_LOCK",
    ]

    /// Keys present in the v1 snapshot format, before Kimi-specific identity settings were added.
    static let legacyCapturedKeys = [
        "CLAUDE_CONFIG_DIR", "CODEX_HOME", "XDG_CONFIG_HOME",
        "USER_TYPE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
        "CLAUDE_LOCAL_OAUTH_API_BASE", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
    ]

    /// Captured values. An absent pinned key was verifiably NOT exported at capture time, so it reads
    /// as "no override" for the process lifetime.
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

    /// Values for every captured key as the (warm) login-shell layer reports them, or `nil` when the
    /// capture failed — a real login shell always exports PATH/HOME, so an empty capture means the
    /// spawn or parse failed and its "facts" must not be persisted.
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

/// UserDefaults persistence for the snapshot (`openusage.shellEnvSnapshot.v2`). A class so the
/// post-launch refresh task can carry it across actors; UserDefaults itself is thread-safe.
final class ShellEnvironmentSnapshotStore: @unchecked Sendable {
    static let storageKey = "openusage.shellEnvSnapshot.v2"
    static let previousStorageKey = "openusage.shellEnvSnapshot.v1"

    /// The snapshot as it existed at process start, decoded once and memoized (a `static let` is
    /// thread-safe lazy). `ProcessEnvironmentReader` consults this on every identity-key read, so it
    /// must not re-hit UserDefaults each time. Deliberately frozen for the process lifetime — that
    /// freeze IS the session pin; the refresh task's newer facts apply from the next launch.
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

    /// Wait (off-main, bounded by the capture's own subprocess timeout) for the login-shell capture
    /// kicked off by `prewarm()`, then persist a fresh snapshot of its facts. A failed capture
    /// persists nothing — the previous snapshot's facts stay in place. Callers retain the task and
    /// cancel it on teardown.
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
