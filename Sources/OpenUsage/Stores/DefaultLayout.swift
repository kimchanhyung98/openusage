import Foundation

/// 최초 실행 시 활성화되는 metric 기본값
/// `LayoutStore`가 활성 registry 기준으로 필터링 — 미정의 ID는 무시
/// provider 섹션 순서는 여기서 시드하지 않음, 빈 저장 순서는 registry 순서로 정착
enum DefaultLayout {
    static let metricIDs: [String] = [
        "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.claude", "antigravity.claudeWeekly",

        "claude.session", "claude.weekly", "claude.fable", "claude.trend",
        "claude.today", "claude.yesterday",

        "codex.session", "codex.weekly", "codex.trend", "codex.rateLimitResets",
        "codex.today", "codex.yesterday",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30",

        "copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend",
        "copilot.chat", "copilot.completions",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.weekly", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "kimi.session", "kimi.weekly",

        "kiro.credits",

        "opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend",
        "opencode.today", "opencode.yesterday", "opencode.last30",

        "openrouter.credits", "openrouter.balance",
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",

        "zai.session", "zai.weekly", "zai.webSearches"
    ]

    /// default 시딩 도입 릴리스 시점 default-on metric의 고정 snapshot
    /// 시딩 키 없는 기존 사용자는 이미 제안받은 것으로 간주 — 과거 opt-out 유지, 이후 추가분만 자동 노출
    static let migrationBaselineMetricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "claude.extra", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.creditsUsed", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
    ]

    /// 최초 실행 시 메뉴바에 고정되는 metric — 아이콘만 남는 첫 화면 방지, `metricIDs`처럼 registry 필터링
    static let pinnedMetricIDs: [String] = [
        "antigravity.geminiPro", "antigravity.geminiWeekly",
        "claude.weekly",
        "codex.weekly",
        "cursor.auto", "cursor.api",
        "copilot.premium",
        "kimi.weekly",
        "kiro.credits",
        "openrouter.credits",
        "zai.session", "zai.weekly"
    ]

    /// registry의 추가 계정 card(`claude@ab12cd34`)마다 family 항목을 card prefix로 복제해 append
    /// pin은 번역하지 않음 — 추가 계정이 기본으로 메뉴바를 점유하지 않는 규칙
    /// `migrationBaselineMetricIDs`도 번역하지 않음 — card 최초 등장 시 default 시딩 보장
    static func translatedForAccountCards(_ ids: [String], providerIDs: [String]) -> [String] {
        let accountCardIDs = providerIDs.filter(ProviderAccountID.isAccountCard)
        guard !accountCardIDs.isEmpty else { return ids }
        var result = ids
        for cardID in accountCardIDs {
            let prefix = ProviderAccountID.family(of: cardID) + "."
            for id in ids where id.hasPrefix(prefix) {
                result.append("\(cardID).\(id.dropFirst(prefix.count))")
            }
        }
        return result
    }

    /// 신규 설치 시 provider별 On Demand 섹션에 배치되는 metric
    /// 활성화가 아닌 소속 목록 — 비활성 optional row도 나중에 켜면 caret 아래 등장
    /// registry 필터링 적용, 순수 신규 설치에서만 시드
    static let expandedMetricIDs: [String] = [
        // Antigravity: Gemini pool 쌍은 fold 위, Claude pool 쌍은 caret 아래
        "antigravity.claude", "antigravity.claudeWeekly",
        // Claude: Session·Weekly·Fable은 fold 위, Trend·optional limit·Extra Usage·spend history는 caret 아래
        "claude.trend", "claude.extra", "claude.sonnet",
        "claude.today", "claude.yesterday", "claude.last30",
        // Codex: Session·Weekly는 fold 위, Trend·reset 상세·Spark·Extra Usage·spend history는 caret 아래
        "codex.trend", "codex.rateLimitResets", "codex.spark", "codex.sparkWeekly",
        "codex.credits", "codex.today", "codex.yesterday", "codex.last30",
        "cursor.onDemand", "cursor.requests", "cursor.credits",
        "cursor.today", "cursor.yesterday", "cursor.last30",
        // Copilot: Credits·Extra Usage는 fold 위, org billing 쌍과 Chat·Completions는 caret 아래 — Chat·Completions는 free에서만 실측치
        "copilot.orgCredits", "copilot.orgSpend", "copilot.chat", "copilot.completions",
        "devin.extra",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",
        // OpenCode: Go cap 3종과 Trend는 fold 위, spend tile은 caret 아래
        "opencode.today", "opencode.yesterday", "opencode.last30",
        // OpenRouter: Credits meter·Balance는 fold 위, 기간 spend·key cap은 caret 아래
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",
        // Z.ai: Session meter는 fold 위, Web Searches는 caret 아래
        "zai.webSearches"
    ]
}
