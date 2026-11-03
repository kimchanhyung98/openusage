import Foundation

struct ZAIAuth: Hashable, Sendable {
    var apiKey: String
}

enum ZAIAuthError: Error, LocalizedError, Equatable {
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
            return "No Z.ai API key. Set ZAI_API_KEY or add it to ~/.config/openusage/zai.json."
        case .invalidKey:
            return "Z.ai API key invalid. Check your key at z.ai/manage-apikey/apikey-list."
        case .saveFailed:
            return "Couldn't save the Z.ai API key."
        case .deleteFailed:
            return "Couldn't remove the saved Z.ai API key."
        }
    }
}

/// 사용자가 머신에 이미 둔 Z.ai(Zhipu AI) API key 읽기 — companion CLI/앱이 없어 환경 변수 또는 config 파일이 소스.
/// Finder/Dock 실행 GUI 앱은 interactive shell 환경을 상속받지 못함 — `ProcessEnvironmentReader`가 실행 시
/// login shell 환경을 capture하므로(`LoginShellEnvironment` 참고) shell profile의 export도 packaged build에서 유효.
struct ZAIAuthStore: Sendable {
    /// 순서대로 확인하는 config 파일 — 처음 읽히는 key 사용. JSON(`apiKey`/`api_key`/`key`) 또는 key만 담긴 plain text.
    static let configPaths = [
        "~/.config/openusage/zai.json",
        "~/.config/zai/key.json"
    ]
    /// 순서대로 확인하는 환경 변수 — `ZAI_API_KEY`가 현행, `GLM_API_KEY`는 아직 쓰이는 구 Zhipu 이름.
    static let environmentNames = ["ZAI_API_KEY", "GLM_API_KEY"]

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
            makeError: { ZAIAuthError($0) }
        )
    }

    func loadAPIKey() -> ZAIAuth? { store.loadKey().map(ZAIAuth.init(apiKey:)) }
    func currentAPIKey() -> String? { store.loadKey() }
    func keyStatus() -> APIKeyStatus { store.keyStatus() }
    func saveAPIKey(_ key: String) throws { try store.saveKey(key) }
    func deleteAPIKey() throws { try store.deleteKey() }
}
