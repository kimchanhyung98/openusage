import Foundation

struct OpenRouterAuth: Hashable, Sendable {
    var apiKey: String
}

enum OpenRouterAuthError: Error, LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case saveFailed
    case deleteFailed

    init(_ failure: UserAPIKeyStore.Failure) {
        switch failure {
        case .missingKey: self = .missingKey
        case .saveFailed: self = .saveFailed
        case .deleteFailed: self = .deleteFailed
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "No OpenRouter API key. Set OPENROUTER_API_KEY or add it to ~/.config/openusage/openrouter.json."
        case .invalidKey:
            return "OpenRouter API key invalid. Check your key at openrouter.ai/keys."
        case .saveFailed:
            return "Couldn't save the OpenRouter API key."
        case .deleteFailed:
            return "Couldn't remove the saved OpenRouter API key."
        }
    }
}

/// 사용자가 머신에 이미 둔 OpenRouter API key 읽기 — companion 앱이 없어 환경 변수 또는 config 파일이 소스.
/// Finder/Dock 실행 GUI 앱은 interactive shell 환경을 상속받지 못함 — `ProcessEnvironmentReader`가 실행 시
/// login shell 환경을 capture하므로(`LoginShellEnvironment` 참고) shell profile의 export도 packaged build에서 유효.
struct OpenRouterAuthStore: Sendable {
    /// 순서대로 확인하는 config 파일 — 처음 읽히는 key 사용. JSON(`apiKey`/`api_key`/`key`) 또는 key만 담긴 plain text.
    static let configPaths = [
        "~/.config/openusage/openrouter.json",
        "~/.config/openrouter/key.json"
    ]
    /// 순서대로 확인하는 환경 변수 — `OPENROUTER_API_KEY`가 사실상 표준.
    static let environmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]

    private let store: UserAPIKeyStore

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader()
    ) {
        store = UserAPIKeyStore(
            configPaths: Self.configPaths,
            environmentNames: Self.environmentNames,
            files: files,
            environment: environment,
            makeError: { OpenRouterAuthError($0) }
        )
    }

    func loadAPIKey() -> OpenRouterAuth? { store.loadKey().map(OpenRouterAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
