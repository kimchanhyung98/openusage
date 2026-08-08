import Foundation

/// pi session 로그의 `provider` 필드를 usage가 귀속될 OpenUsage provider 카드로 매핑.
/// pi는 다른 provider 모델을 구동하는 BYO-key agent — usage는 자체 카드가 아닌 기반 provider(pi 안의 Claude sub는 Claude 카드)로 귀속.
/// OpenUsage 카드가 있는 provider만 나열(`nvidia-nim` 등은 의도적 부재). 매핑만 되고 아직 미소비: `cursor`(CSV 기반 trend), `zai`/`zhipu`, `google-antigravity`, `github-copilot` — 현재 pi slice는 Claude·Codex만 읽음.
enum PiProviderMapping {
    /// pi `provider` 값 → OpenUsage `Provider.id`.
    static let providerToCard: [String: String] = [
        "anthropic": "claude",
        "claude-agent-sdk": "claude",
        "openai-codex": "codex",
        "cursor": "cursor",
        "zai": "zai",
        "zhipu": "zai",
        "google-antigravity": "antigravity",
        "github-copilot": "copilot"
    ]

    static func cardID(forPiProvider provider: String) -> String? {
        providerToCard[provider]
    }
}
