import Foundation

/// 일 단위 priced usage(tokens·cost·모델별 breakdown)를 누적해 `LogUsageScan`으로 조립.
/// Claude·Codex·Grok 로그 scanner가 공유하는 공통 꼬리 — priced row만 집계하고, unpriceable 모델은 경고 삼각형용으로 별도 추적.
struct DailyUsageAccumulator {
    private var tokensByDay: [String: Int] = [:]
    private var costByDay: [String: Double] = [:]
    private var unknownModelsByDay: [String: Set<String>] = [:]
    private var modelsByDay: [String: [String: ModelAccumulator]] = [:]

    /// 로컬 캘린더 기준 `yyyy-MM-dd` day key — accumulator·`SpendTileMapper`·Cursor CSV 집계가 공유하는 단일 계약.
    static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    mutating func add(day: String, tokens: Int, cost: Double, model: String) {
        tokensByDay[day, default: 0] += tokens
        costByDay[day, default: 0] += cost
        modelsByDay[day, default: [:]][model, default: ModelAccumulator()].add(tokens: tokens, costUSD: cost)
    }

    /// 이미 만들어진 scan들(native + pi slice)을 하나로 병합 — 모델별 daily usage를 새 accumulator로 재생해 일관성 유지.
    /// 모든 입력은 accumulator 기반이어야 함(native·pi scanner가 보장). nil 입력은 건너뛰고 전부 nil이면 nil 반환.
    static func merged(_ scans: [LogUsageScan?]) -> LogUsageScan? {
        let present = scans.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        var accumulator = DailyUsageAccumulator()
        for scan in present {
            for day in scan.modelUsage?.daily ?? [] {
                for model in day.models {
                    // cost-unknown 항목은 $0로 치지 않고 건너뜀 — unknown-model 정보는 아래 unknownModelsByDay로 별도 반영.
                    guard let cost = model.costUSD else { continue }
                    accumulator.add(day: day.date, tokens: model.totalTokens, cost: cost, model: model.model)
                }
            }
            for (day, models) in scan.unknownModelsByDay {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }
        return accumulator.build()
    }

    /// 가격 산정은 불가하지만 tokens는 있는 모델 기록 — 타일 경고 삼각형에만 표시되고 모든 합계에서 제외.
    mutating func addUnknownModel(day: String, model: String) {
        unknownModelsByDay[day, default: []].insert(model)
    }

    /// scan 조립: 일별 tokens/cost(최신순), 모델별 breakdown, unknown-model 집합.
    /// 집계된 날은 전부 priced — `costUSD`는 항상 실제 합계.
    func build() -> LogUsageScan {
        let days = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(date: day, totalTokens: tokensByDay[day] ?? 0, costUSD: costByDay[day] ?? 0)
        }
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                models: modelsByDay[day, default: [:]].map { model, accumulator in accumulator.entry(model: model) }
            )
        })
        return LogUsageScan(
            series: DailyUsageSeries(daily: days),
            modelUsage: modelUsage,
            unknownModelsByDay: unknownModelsByDay
        )
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?

        mutating func add(tokens: Int, costUSD: Double?) {
            self.tokens += tokens
            if let costUSD {
                self.costUSD = (self.costUSD ?? 0) + costUSD
            }
        }

        func entry(model: String) -> ModelUsageEntry {
            ModelUsageEntry(model: model, totalTokens: tokens, costUSD: costUSD)
        }
    }
}
