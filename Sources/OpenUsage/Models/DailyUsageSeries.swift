import Foundation

/// 모든 spend-tracking provider가 `SpendTileMapper`로 넘기는 provider 중립 일별 token/cost series.
/// 직렬화 무관 internal 타입 — local HTTP API는 `MetricLine`만 직렬화.
struct DailyUsageEntry: Hashable, Sendable, Codable {
    var date: String
    var totalTokens: Int
    var costUSD: Double?
}

struct DailyUsageSeries: Hashable, Sendable, Codable {
    var daily: [DailyUsageEntry]
}

/// local scanner·iCloud 통합 history·usage trend가 공유하는 calendar window.
/// `previousDays`는 오늘 제외 — 30이면 오늘 + 이전 30일.
enum UsageHistoryWindow {
    static let previousDays = 30

    static func dayKeys(through now: Date, calendar: Calendar = .current) -> Set<String> {
        let today = calendar.startOfDay(for: now)
        return Set((0...previousDays).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today)
                .map { DailyUsageAccumulator.dayKey(from: $0, calendar: calendar) }
        })
    }
}

/// 기간 집계 전 model 하나의 token/cost 합계 — cost는 여기서 비반올림, `SpendTileMapper`가 표시 시점에 한 번만 cent로 반올림.
/// `variants`는 base model group 시 접힌 raw slug 목록 — 정확히 raw model 하나면 nil (hover panel의 추가 breakdown 없음 신호).
struct ModelUsageEntry: Hashable, Sendable, Codable {
    static let unattributedModelName = "Unattributed"
    static let otherModelName = "Other"

    var model: String
    var totalTokens: Int
    var costUSD: Double?
    var variants: [ModelUsageVariant]? = nil
}

/// group된 `ModelUsageEntry` 안의 raw slug 하나 — hover panel row tooltip의 per-variant 줄.
struct ModelUsageVariant: Hashable, Sendable, Codable {
    var model: String
    var totalTokens: Int
    var costUSD: Double?
}

struct DailyModelUsageEntry: Hashable, Sendable, Codable {
    var date: String
    var models: [ModelUsageEntry]
}

struct ModelUsageSeries: Hashable, Sendable, Codable {
    var daily: [DailyModelUsageEntry]
}

/// provider snapshot에 유지되는 presentation 무관 일별 history.
/// descriptor가 machine-local로 분류한 경우에만 private iCloud sync 파일에 기록.
struct ProviderUsageHistory: Hashable, Sendable, Codable {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    var unknownModelsByDay: [String: Set<String>]

    init(
        series: DailyUsageSeries,
        modelUsage: ModelUsageSeries? = nil,
        unknownModelsByDay: [String: Set<String>] = [:]
    ) {
        self.series = series
        self.modelUsage = modelUsage
        self.unknownModelsByDay = unknownModelsByDay
    }
}

/// spend row와 같은 `.values` line에 붙는 기간 단위 UI용 model breakdown.
/// header 합계는 해당 row 값과 동일, 개별 model cost는 이 표시 경계에서 반올림.
struct ModelUsageBreakdown: Hashable, Sendable, Codable {
    var totalTokens: Int
    var totalCostUSD: Double?
    var models: [ModelUsageEntry]
    var sourceNote: String
}

/// 일별 token/cost series + 날짜별 미가격 model 목록 — `SpendTileMapper.appendTokenUsage`의 입력.
/// native log scanner(Claude, Codex)의 공용 결과 shape.
struct LogUsageScan: Sendable {
    var series: DailyUsageSeries
    var modelUsage: ModelUsageSeries?
    /// `yyyy-MM-dd` day key → 가격 부재로 합계에서 제외된 그날의 model 목록.
    var unknownModelsByDay: [String: Set<String>]

    init(series: DailyUsageSeries, modelUsage: ModelUsageSeries? = nil, unknownModelsByDay: [String: Set<String>]) {
        self.series = series
        self.modelUsage = modelUsage
        self.unknownModelsByDay = unknownModelsByDay
    }
}
