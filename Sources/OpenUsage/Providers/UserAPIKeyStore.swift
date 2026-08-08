import Foundation

/// 기기에 이미 있는 user-supplied API key(환경 변수 또는 작은 JSON/plain-text config file) — credential을 남기는 동반 CLI/앱이 없는 provider(OpenRouter, Z.ai)용.
/// read/status/save/delete 전부가 여기 있어 각 provider는 config 경로·env-var 이름·오류 메시지만 갖는 얇은 wrapper.
/// Finder/Dock에서 실행된 GUI 앱은 interactive shell 환경을 상속하지 않음 — `ProcessEnvironmentReader`가 launch 시 login shell 환경을 capture(`LoginShellEnvironment`)해 shell profile의 export도 패키지 빌드에서 유효.
struct UserAPIKeyStore: Sendable {
    /// wrapper가 자기 provider 오류로 매핑하는 save/delete 실패 — user-facing 메시지 보존.
    enum Failure { case missingKey, saveFailed, deleteFailed }

    let configPaths: [String]
    let environmentNames: [String]
    var files: TextFileAccessing
    var environment: EnvironmentReading
    let makeError: @Sendable (Failure) -> Error

    /// config file 우선, 환경 변수 차선 — config file이 키 교체 시 사용자가 편집하는 경로라 낡은 `launchctl setenv` 잔여값보다 우선.
    func loadKey() -> String? {
        keyFromConfigFile() ?? keyFromEnvironment()
    }

    /// 현재 key를 쥔 source 조합 — 4-state per-provider API-key 편집기 구동. 저장 key + env key는 config 우선이라 `overrideActive`.
    func keyStatus() -> APIKeyStatus {
        let hasConfig = keyFromConfigFile() != nil
        let hasEnv = keyFromEnvironment() != nil
        switch (hasConfig, hasEnv) {
        case (true, true): return .overrideActive
        case (true, false): return .saved
        case (false, true): return .fromEnvironment
        default: return .notSet
        }
    }

    /// primary config file에 JSON `{"apiKey":"…"}`로 저장 — 낡은 env var보다 우선하므로 "override" 경로이기도 함. 빈 입력은 `.missingKey`.
    func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw makeError(.missingKey) }
        let data = try JSONSerialization.data(withJSONObject: ["apiKey": trimmed], options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw makeError(.saveFailed) }
        do {
            try files.writeText(configPaths[0], text)
        } catch {
            AppLog.error(.auth, "save API key to \(configPaths[0]) failed: \(error.localizedDescription)")
            throw makeError(.saveFailed)
        }
    }

    /// primary만이 아닌 모든 config 경로에서 저장 key 제거 — 대체 경로의 key가 되살아나지 않도록. 없는 파일은 no-op.
    func deleteKey() throws {
        for path in configPaths {
            guard files.exists(path) else { continue }
            do {
                try files.remove(path)
            } catch {
                AppLog.error(.auth, "delete API key at \(path) failed: \(error.localizedDescription)")
                throw makeError(.deleteFailed)
            }
        }
    }

    private func keyFromEnvironment() -> String? {
        for name in environmentNames {
            if let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func keyFromConfigFile() -> String? {
        for path in configPaths {
            guard files.exists(path), let text = try? files.readText(path) else { continue }
            if let key = Self.keyFromConfigText(text) {
                return key
            }
        }
        return nil
    }

    /// `apiKey` / `api_key` / `key`를 가진 JSON 객체 또는 key만 담긴 plain-text 파일 허용.
    static func keyFromConfigText(_ text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for field in ["apiKey", "api_key", "key"] {
                if let value = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        // JSON 아님 — 빈 줄 무시하고 plain-text key 파일로 취급.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("{") ? nil : trimmed
    }
}
