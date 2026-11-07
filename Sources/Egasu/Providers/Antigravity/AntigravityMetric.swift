import Foundation

/// Antigravity의 위젯 ID 4개와 metric 라벨 — `AntigravityProvider.widgetDescriptors`와 `AntigravityUsageMapper`가 공유해 exact-string 라벨 바인딩(`WidgetDescriptor.metricLabel` == `MetricLine.label`)의 drift 방지. drift는 조용한 "No data" 실패.
/// 2026-05-19 quota pool 병합: Gemini Pro/Flash가 한 pool, 비Gemini 모델(Claude, GPT-OSS)이 두 번째 pool 공유 — pool마다 rolling 5시간 + weekly window. Gemini pool 쌍은 Claude/Codex 행에 맞춰 "Session"/"Weekly", 비Gemini pool은 Codex의 Spark 쌍처럼 "Claude" 이름 유지.
/// `geminiID`는 기존 사용자의 layout 상태(enabled/pin/order)가 무이관 승계되도록 역사적 `antigravity.geminiPro` raw 값 유지.
enum AntigravityMetric {
    static let geminiID = "antigravity.geminiPro"
    static let geminiWeeklyID = "antigravity.geminiWeekly"
    static let claudeID = "antigravity.claude"
    static let claudeWeeklyID = "antigravity.claudeWeekly"

    static let sessionLabel = "Session"
    static let weeklyLabel = "Weekly"
    static let claudeLabel = "Claude"
    static let claudeWeeklyLabel = "Claude Weekly"
}
