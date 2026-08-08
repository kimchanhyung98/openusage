import Foundation

/// 로컬 일별 token/cost 데이터를 공용 Today / Yesterday / Last 30 Days spend 타일로 변환.
/// 모든 spend 추적 provider가 여기를 거쳐 타일 렌더 통일 — Claude/Codex/Grok은 CLI 로그, Cursor는 CSV export가 공급하고, `DailyUsageSeries`가 provider 중립 per-day carrier.
enum SpendTileMapper {
    /// 세 spend 타일(Today / Yesterday / Last 30 Days) 추가. usage 없는 기간은 타일을 만들지 않아 "No data" — 여기서의 0은 "아직 집계 전"과 구분 불가라 자신 있는 `$0.00 · 0 tokens`는 금지. source 읽기 실패 시에도 호출자가 아무것도 추가하지 않음.
    /// `estimated`는 달러 값의 로컬 추정 마커(ⓘ) 여부. `unknownModelsByDay`는 `yyyy-MM-dd` day key → 가격 산정 불가 모델 집합 — Today/Yesterday는 자기 날의 집합, Last 30 Days는 window 전체의 합집합.
    static func appendTokenUsage(
        _ usage: DailyUsageSeries,
        to lines: inout [MetricLine],
        now: Date = Date(),
        estimated: Bool = true,
        unknownModelsByDay: [String: Set<String>] = [:],
        modelUsage: ModelUsageSeries? = nil,
        modelSourceNote: String? = nil
    ) {
        let today = dayKey(from: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now).map(dayKey(from:))

        if let entry = usage.daily.first(where: { dayKey(fromUsageDate: $0.date) == today }), hasUsage(entry) {
            lines.append(dayUsageLine(label: "Today", entry: entry, estimated: estimated,
                                      unknownModels: sortedModels(unknownModelsByDay[today]),
                                      modelBreakdown: modelBreakdown(
                                        modelUsage,
                                        days: [today],
                                        totalTokens: entry.totalTokens,
                                        totalCostUSD: entry.costUSD,
                                        sourceNote: modelSourceNote
                                      )))
        }
        if let entry = usage.daily.first(where: { dayKey(fromUsageDate: $0.date) == yesterday }), hasUsage(entry) {
            lines.append(dayUsageLine(label: "Yesterday", entry: entry, estimated: estimated,
                                      unknownModels: sortedModels(yesterday.flatMap { unknownModelsByDay[$0] }),
                                      modelBreakdown: modelBreakdown(
                                        modelUsage,
                                        days: Set([yesterday].compactMap { $0 }),
                                        totalTokens: entry.totalTokens,
                                        totalCostUSD: entry.costUSD,
                                        sourceNote: modelSourceNote
                                      )))
        }

        let totalTokens = usage.daily.reduce(0) { $0 + $1.totalTokens }
        let costSamples = usage.daily.compactMap(\.costUSD)
        let totalCost = costSamples.isEmpty ? nil : costSamples.reduce(0, +)
        if totalTokens > 0 || (totalCost ?? 0) > 0 {
            let allUnknown = unknownModelsByDay.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            lines.append(.values(label: "Last 30 Days",
                                 values: spendValues(tokens: totalTokens, costUSD: totalCost, estimated: estimated),
                                 unknownModels: sortedModels(allUnknown),
                                 modelBreakdown: modelBreakdown(
                                    modelUsage,
                                    days: Set(usage.daily.compactMap { dayKey(fromUsageDate: $0.date) }),
                                    totalTokens: totalTokens,
                                    totalCostUSD: totalCost,
                                    sourceNote: modelSourceNote
                                 )))
        }
    }

    /// 실사용이 있는 기간: tokens 사용, 달러 산정, 또는 둘 다. 0-token·0-cost 날은 idle — 타일 없이 "No data".
    private static func hasUsage(_ entry: DailyUsageEntry) -> Bool {
        entry.totalTokens > 0 || (entry.costUSD ?? 0) > 0
    }

    /// Usage Trend chart line 추가: window 안 하루당 막대 하나, 값은 그날 사용 tokens.
    /// window 전체가 idle이면 아무것도 추가하지 않음 — 0 막대 행 대신 "No data".
    static func appendUsageTrend(_ usage: DailyUsageSeries, to lines: inout [MetricLine], now: Date = Date(), note: String) {
        let points = trendPoints(usage, now: now)
        guard !points.isEmpty else { return }
        lines.append(.chart(label: "Usage Trend", points: points, note: note))
    }

    /// 조회 window(오늘 + 이전 30일)의 일별 token point, 과거순. 같은 날짜로 normalize되는 source row들은 막대 하나로 합산.
    /// idle 날은 drop이 아닌 0 채움 — sparkline이 calendar-true 유지(빈 날이 이웃으로 붕괴되지 않음). window에 사용이 없으면 빈 배열.
    private static func trendPoints(_ usage: DailyUsageSeries, now: Date) -> [MetricChartPoint] {
        var tokensByDay: [String: Double] = [:]
        for day in usage.daily {
            let tokens = Double(day.totalTokens)
            guard tokens.isFinite, tokens >= 0, let key = dayKey(fromUsageDate: day.date) else { continue }
            tokensByDay[key, default: 0] += tokens
        }
        guard tokensByDay.values.contains(where: { $0 > 0 }) else { return [] }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        return (0...UsageHistoryWindow.previousDays).reversed().compactMap { offset -> MetricChartPoint? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = dayKey(from: day)
            let tokens = tokensByDay[key] ?? 0
            return MetricChartPoint(
                value: tokens,
                // 하드코딩 "6/21"이 아닌 앱의 localized "Jun 21" 표기.
                label: Formatters.monthDayLabel(day),
                valueLabel: MetricFormatter.number(tokens, kind: .count, style: .row) + " tokens"
            )
        }
    }

    private static func dayKey(from date: Date) -> String {
        DailyUsageAccumulator.dayKey(from: date)
    }

    private static func dayKey(fromUsageDate rawDate: String) -> String? {
        let value = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil {
            return value
        }

        if let date = OpenUsageISO8601.date(from: value) {
            return dayKey(from: date)
        }

        if let match = value.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            return String(value[match])
        }
        if value.range(of: #"^\d{8}$"#, options: .regularExpression) != nil {
            let year = value.prefix(4)
            let month = value.dropFirst(4).prefix(2)
            let day = value.suffix(2)
            return "\(year)-\(month)-\(day)"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        if let date = formatter.date(from: value) {
            return dayKey(from: date)
        }

        return nil
    }

    private static func dayUsageLine(
        label: String,
        entry: DailyUsageEntry,
        estimated: Bool,
        unknownModels: [String],
        modelBreakdown: ModelUsageBreakdown?
    ) -> MetricLine {
        .values(label: label, values: spendValues(tokens: entry.totalTokens, costUSD: entry.costUSD, estimated: estimated),
                unknownModels: unknownModels, modelBreakdown: modelBreakdown)
    }

    /// 기간의 unknown-model 이름의 안정적·중복 제거된 표시 순서 (집합은 무순서).
    private static func sortedModels(_ models: Set<String>?) -> [String] {
        (models ?? []).sorted()
    }

    /// 한 기간의 spend raw 값: 추정 달러 + 측정 token 수, "$4.08 · 1.2M tokens"로 합쳐 렌더.
    /// 실사용 있는 기간에만 호출(`hasUsage`). `estimated`는 로컬 계산 달러에만 ⓘ — token 수는 항상 측정값이라 표시 없음.
    private static func spendValues(tokens: Int, costUSD: Double?, estimated: Bool) -> [MetricValue] {
        var values: [MetricValue] = []
        if let costUSD {
            values.append(MetricValue(number: costUSD, kind: .dollars, estimated: estimated))
        }
        values.append(MetricValue(number: Double(tokens), kind: .count, label: "tokens"))
        return values
    }

    private static let namedModelCap = 5

    /// case-fold된 한 이름의 표기들을 추적해 tokens를 가장 많이 실은 표기 선출(동률은 소문자, 다음 알파벳순) — `GLM-5.2`와 `glm-5.2`가 우세한 표기 제목의 한 행으로 병합.
    private struct SpellingVote {
        private var tokensBySpelling: [String: Int] = [:]

        mutating func note(_ spelling: String, weight: Int) {
            // 0-token 항목(cost-only line)도 투표권 보유.
            tokensBySpelling[spelling, default: 0] += max(weight, 1)
        }

        var best: String? {
            tokensBySpelling.min { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                let lhsLower = lhs.key == lhs.key.lowercased()
                let rhsLower = rhs.key == rhs.key.lowercased()
                if lhsLower != rhsLower { return lhsLower }
                return lhs.key < rhs.key
            }?.key
        }
    }

    private struct ModelAccumulator {
        var tokens = 0
        var costUSD: Double?
        private var nameVote = SpellingVote()
        /// case-fold된 slug가 key — 내부 vote가 표시 표기를 복원.
        private var variants: [String: (tokens: Int, costUSD: Double?, vote: SpellingVote)] = [:]

        /// 병합된 모든 casing에서 선출된 이 모델의 표시 표기.
        var displayName: String? { nameVote.best }

        /// 같은 모델의 day entry 병합 — variant(raw slug)는 line 단위로 합쳐 여러 날 기간에도 slug당 한 line 유지.
        mutating func add(_ entry: ModelUsageEntry, spelledAs name: String) {
            addTotals(of: entry, spelledAs: name)
            for variant in entry.variants ?? [ModelUsageVariant(model: name, totalTokens: entry.totalTokens, costUSD: entry.costUSD)] {
                mergeVariant(variant.model, tokens: variant.totalTokens, costUSD: variant.costUSD)
            }
        }

        /// 다른 모델을 이 accumulator(Other 행)로 흡수 — 흡수된 모델당 variant 하나, tooltip은 raw effort slug가 아닌 모델명 나열. Other 행 이름은 고정이라 흡수된 표기는 variant line 안에서만 투표.
        mutating func fold(_ entry: ModelUsageEntry) {
            tokens += entry.totalTokens
            if let cost = entry.costUSD {
                costUSD = (costUSD ?? 0) + cost
            }
            mergeVariant(entry.model, tokens: entry.totalTokens, costUSD: entry.costUSD)
        }

        private mutating func addTotals(of entry: ModelUsageEntry, spelledAs name: String) {
            tokens += entry.totalTokens
            if let cost = entry.costUSD {
                costUSD = (costUSD ?? 0) + cost
            }
            nameVote.note(name, weight: entry.totalTokens)
        }

        private mutating func mergeVariant(_ model: String, tokens: Int, costUSD: Double?) {
            let key = model.lowercased()
            var existing = variants[key] ?? (0, nil, SpellingVote())
            existing.tokens += tokens
            existing.costUSD = costUSD.map { (existing.costUSD ?? 0) + $0 } ?? existing.costUSD
            existing.vote.note(model, weight: tokens)
            variants[key] = existing
        }

        func entry(model: String) -> ModelUsageEntry {
            let list = variants
                .map { key, value in
                    ModelUsageVariant(model: value.vote.best ?? key, totalTokens: value.tokens,
                                      costUSD: value.costUSD.map(SpendTileMapper.roundToCents))
                }
                .sorted(by: variantSortPrecedes)
            // 행 자신의 이름만 실은 variant 하나는 breakdown이 아님 — nil로 tooltip을 수치만으로 유지.
            let isTrivial = list.count == 1 && list[0].model.lowercased() == model.lowercased()
            return ModelUsageEntry(model: model, totalTokens: tokens,
                                   costUSD: costUSD.map(SpendTileMapper.roundToCents),
                                   variants: isTrivial ? nil : list)
        }
    }

    private static func variantSortPrecedes(_ lhs: ModelUsageVariant, _ rhs: ModelUsageVariant) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    private static func modelBreakdown(
        _ usage: ModelUsageSeries?,
        days: Set<String>,
        totalTokens: Int,
        totalCostUSD: Double?,
        sourceNote: String?
    ) -> ModelUsageBreakdown? {
        guard let usage, let sourceNote, !days.isEmpty else { return nil }

        // case-fold된 이름이 key — `GLM-5.2`와 `glm-5.2`가 한 행에 모이고, accumulator의 표기 투표가 제목 casing 결정.
        var byModel: [String: ModelAccumulator] = [:]
        for day in usage.daily where dayKey(fromUsageDate: day.date).map(days.contains) == true {
            for model in day.models where model.totalTokens > 0 || (model.costUSD ?? 0) > 0 {
                let name = normalizedModelName(model.model)
                byModel[name.lowercased(), default: ModelAccumulator()].add(model, spelledAs: name)
            }
        }

        let sorted = byModel.map { key, accumulator in accumulator.entry(model: accumulator.displayName ?? key) }
            .sorted(by: modelSortPrecedes)
        let folded = foldModelList(sorted)
        guard !folded.isEmpty else { return nil }
        return ModelUsageBreakdown(
            totalTokens: totalTokens,
            totalCostUSD: totalCostUSD,
            models: folded,
            sourceNote: sourceNote
        )
    }

    private static func normalizedModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ModelUsageEntry.unattributedModelName : trimmed
    }

    private static func modelSortPrecedes(_ lhs: ModelUsageEntry, _ rhs: ModelUsageEntry) -> Bool {
        let lhsCost = lhs.costUSD ?? 0
        let rhsCost = rhs.costUSD ?? 0
        if lhsCost != rhsCost { return lhsCost > rhsCost }
        if lhs.totalTokens != rhs.totalTokens { return lhs.totalTokens > rhs.totalTokens }
        return lhs.model.localizedStandardCompare(rhs.model) == .orderedAscending
    }

    /// 기간 내 이 비중 미만 모델은 순위와 무관하게 Other로 흡수 — 5% 미만 조각 더미는 노이즈, Other tooltip이 이름은 유지.
    private static let minVisibleShare = 0.05

    private static func foldModelList(_ entries: [ModelUsageEntry]) -> [ModelUsageEntry] {
        // threshold는 패널 percent 라벨과 같은 기준 사용(전 모델 priced면 cost 비중, 아니면 token 비중 — `ModelUsageDetail.share`) — 아니면 5%+로 표시될 모델이 접힐 수 있음.
        let allPriced = entries.allSatisfy { $0.costUSD != nil }
        let costTotal = entries.reduce(0.0) { $0 + ($1.costUSD ?? 0) }
        let tokenTotal = entries.reduce(0) { $0 + $1.totalTokens }
        func share(_ entry: ModelUsageEntry) -> Double {
            if allPriced, costTotal > 0 { return (entry.costUSD ?? 0) / costTotal }
            guard tokenTotal > 0 else { return 0 }
            return Double(entry.totalTokens) / Double(tokenTotal)
        }

        var visible: [ModelUsageEntry] = []
        var other = ModelAccumulator()
        var namedCount = 0

        for entry in entries {
            // 로그가 모델에 귀속 못 한 tokens(Grok)는 "Unattributed" 행 대신 크기와 무관하게 Other로 — 패널은 회계 장부가 아니라 인사이트.
            let isUnattributed = entry.model.caseInsensitiveCompare(ModelUsageEntry.unattributedModelName) == .orderedSame
            if isUnattributed || share(entry) < minVisibleShare {
                other.fold(entry)
            } else if entry.costUSD == nil {
                visible.append(entry)
                namedCount += 1
            } else if namedCount < namedModelCap {
                visible.append(entry)
                namedCount += 1
            } else {
                other.fold(entry)
            }
        }

        if other.tokens > 0 || (other.costUSD ?? 0) > 0 {
            visible.append(other.entry(model: ModelUsageEntry.otherModelName))
        }
        return visible
    }

    private static func roundToCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
