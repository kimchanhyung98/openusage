import Foundation

/// 일별 토큰·모델 내역 누적. 비용이 없는 기여는 토큰을 유지하고 해당 합계의 비용을 미확정으로 처리.
struct DailyUsageAccumulator {
    private var tokensByDay: [String: Int] = [:]
    private var costByDay: [String: UsageCostTotal] = [:]
    private var unknownModelsByDay: [String: Set<String>] = [:]
    private var modelsByDay: [String: [String: ModelAccumulator]] = [:]
    private var totalTokens = 0
    private var totalCost = UsageCostTotal()
    private var rejectedNumericRows = 0

    /// 로컬 캘린더 기준 `yyyy-MM-dd` day key — accumulator·`SpendTileMapper`·Cursor CSV 집계가 공유하는 단일 계약.
    static func dayKey(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    mutating func add(day: String, tokens: Int, cost: Double?, model: String) {
        if tokens == 0 && cost == nil { return }
        let nextTotal = totalTokens.addingReportingOverflow(tokens)
        let nextCost = totalCost.knownTotal + (cost ?? 0)
        // 비음수 전체 합계가 Int 범위 안이면 그 부분집합인 날짜·모델·기간 합계도 안전. 비용·token을 함께 반영.
        guard tokens >= 0, !nextTotal.overflow, cost.map({ $0.isFinite && $0 >= 0 }) ?? true, nextCost.isFinite
        else {
            rejectNumericRow()
            return
        }
        totalTokens = nextTotal.partialValue
        totalCost.add(cost)
        tokensByDay[day, default: 0] += tokens
        costByDay[day, default: UsageCostTotal()].add(cost)
        modelsByDay[day, default: [:]][model, default: ModelAccumulator()].add(tokens: tokens, costUSD: cost)
    }

    mutating func rejectNumericRow() {
        rejectedNumericRows += 1
    }

    /// 모델별 내역을 재생하여 native·공유 도구 이력 병합. nil 입력만 있으면 nil 반환.
    static func merged(_ scans: [LogUsageScan?]) -> LogUsageScan? {
        let present = scans.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        var accumulator = DailyUsageAccumulator()
        var rejectedNumericRows = 0
        var rejectedMetadataRows = 0
        var unsupportedPricingRows = 0
        for scan in present {
            rejectedNumericRows += scan.rejectedNumericRows
            rejectedMetadataRows += scan.rejectedMetadataRows
            unsupportedPricingRows += scan.unsupportedPricingRows
            let modelDays = scan.modelUsage?.daily ?? []
            for day in modelDays {
                for model in day.models {
                    accumulator.add(day: day.date, tokens: model.totalTokens, cost: model.costUSD, model: model.model)
                }
            }
            let represented = Set(modelDays.map(\.date))
            for day in scan.series.daily where !represented.contains(day.date) {
                accumulator.add(day: day.date, tokens: day.totalTokens, cost: day.costUSD, model: ModelUsageEntry.unattributedModelName)
            }
            for (day, models) in scan.unknownModelsByDay {
                for model in models {
                    accumulator.addUnknownModel(day: day, model: model)
                }
            }
        }
        return accumulator.build(
            rejectedNumericRows: rejectedNumericRows, unsupportedPricingRows: unsupportedPricingRows,
            rejectedMetadataRows: rejectedMetadataRows
        )
    }

    /// 가격 산정 불가 모델의 안내 목록. 토큰 반영은 add에서 별도 처리.
    mutating func addUnknownModel(day: String, model: String) {
        unknownModelsByDay[day, default: []].insert(model)
    }

    /// scan 조립: 일별 tokens/cost(최신순), 모델별 breakdown, unknown-model 집합.
    func build(
        rejectedNumericRows previouslyRejected: Int = 0, source: String = "local-usage",
        reportNumericFailures: Bool = true, unsupportedPricingRows: Int = 0,
        rejectedMetadataRows: Int = 0
    ) -> LogUsageScan {
        if reportNumericFailures { UsageLogNumbers.reportRejectedRows(rejectedNumericRows, source: source) }
        let days = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(date: day, totalTokens: tokensByDay[day] ?? 0, costUSD: costByDay[day]?.value)
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
            unknownModelsByDay: unknownModelsByDay,
            rejectedNumericRows: previouslyRejected + rejectedNumericRows,
            unsupportedPricingRows: unsupportedPricingRows,
            rejectedMetadataRows: rejectedMetadataRows
        )
    }

    private struct ModelAccumulator {
        var tokens = 0
        var cost = UsageCostTotal()

        mutating func add(tokens: Int, costUSD: Double?) {
            self.tokens += tokens
            cost.add(costUSD)
        }

        func entry(model: String) -> ModelUsageEntry {
            ModelUsageEntry(model: model, totalTokens: tokens, costUSD: cost.value)
        }
    }
}
