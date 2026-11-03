import Foundation

/// Customize ▸ API Key 섹션에 표시되는 user-supplied API key의 현재 상태.
/// auth store의 우선순위(config file > env)가 saved key를 자동으로 override로 만드는 구조 — 이 타입은 어떤 조합이 있는지만 보고.
enum APIKeyStatus: Sendable, Equatable {
    case notSet
    case fromEnvironment
    case saved
    case overrideActive
}

/// user-supplied API key가 필요한 `ProviderRuntime` (현재 OpenRouter, Z.ai).
/// auth store가 이미 읽는 config file에 그대로 읽고 쓰는 방식 — 별도의 credential 저장 경로 없음.
@MainActor
protocol APIKeyManaging: ProviderRuntime {
    /// 환경 변수 + 저장된 config file로 계산한 실시간 key 상태.
    var apiKeyStatus: APIKeyStatus { get }
    /// 현재 사용 중인 유효 key (config > env). reveal 토글에서만 노출, 없으면 nil.
    func currentAPIKey() -> String?
    /// auth store가 읽는 config file에 key 저장 — 저장된 key는 env var보다 우선.
    func saveAPIKey(_ key: String) throws
    /// 저장된 key 제거. env key가 있으면 `fromEnvironment`로, 없으면 `notSet`으로 복귀.
    func deleteAPIKey() throws
}
