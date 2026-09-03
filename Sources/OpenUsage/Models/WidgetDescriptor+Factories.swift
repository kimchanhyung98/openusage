import Foundation

/// 공용 descriptor factory — template `WidgetData` 조립 방법을 아는 유일한 곳.
/// template 숫자는 구조용(실데이터 없는 row는 no-data marker 렌더) — 모든 factory가 `used: 0`로 seed.
extension WidgetDescriptor {
    /// bounded 0–100% meter (session/weekly형 quota).
    /// `isSessionWindow`는 "Not started" fresh-window 처리 opt-in (rolling 5시간 session pool).
    static func percent(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        isSessionWindow: Bool = false
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100)
        sample.isSessionWindow = isSessionWindow
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// 공개 reset forecast용 0–100% meter — quota 동작(Used/Left·pace·알림) 미적용.
    static func forecast(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100)
        sample.isForecast = true
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// subtitle이 "$<limit> <limitNoun>"인 bounded dollar meter (noun 기본값 "limit").
    /// `valueWord`는 uncapped fallback(`.values` row)의 trailing word — bounded 렌더에서는 무효.
    static func boundedDollars(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        limitNoun: String? = nil,
        valueWord: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: limit, limitNoun: limitNoun,
                                unboundedValueWord: valueWord))
    }

    /// bounded count meter (예: billing cycle당 request 수) — `periodDurationMs` 지정 시 subtitle에 reset 주기 표시.
    static func boundedCount(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        suffix: String,
        periodDurationMs: Int? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: limit, countSuffix: suffix,
                                periodDurationMs: periodDurationMs))
    }

    /// provider `.values` line 기반 unbounded 숫자 row.
    /// `selection`은 렌더할 값 선택, `valueWord`는 단독 dollar 값의 trailing word. 추정치 ⓘ는 데이터 주도라 parameter 아님.
    static func values(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        selection: ValueSelection = .all,
        valueWord: String? = nil,
        isUsagePeriod: Bool = false,
        traySuffix: String? = nil,
        showsResetExpiries: Bool = false
    ) -> WidgetDescriptor {
        // `kind`는 `.values` 렌더에 미사용(값마다 자체 kind 보유) — count 전용 tile만 `.count`, 그 외 `.dollars`로 seed.
        let kind: MetricKind = { if case .kind(let only) = selection { return only }; return .dollars }()
        var sample = WidgetData(title: title, icon: provider.icon, kind: kind, used: 0, limit: nil,
                                unboundedValueWord: valueWord)
        sample.selection = selection
        sample.isUsagePeriod = isUsagePeriod
        sample.traySuffix = traySuffix
        sample.showsResetExpiries = showsResetExpiries
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// `.values` row의 모든 값을 이어 붙인 combined tile (예: "$4.08 · 1.2M tokens").
    static func combined(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        isUsagePeriod: Bool = false
    ) -> WidgetDescriptor {
        values(id: id, provider: provider, title: title, metricLabel: metricLabel, selection: .all,
               isUsagePeriod: isUsagePeriod)
    }

    /// 모든 spend-tracking provider 공통의 local-spend tile 3종 (Today / Yesterday / Last 30 Days) — `SpendTileMapper` 기반.
    /// id는 `<provider>.today|yesterday|last30` — Claude / Codex / Cursor / Grok에서 동일 집합.
    static func spendTiles(provider: Provider, valueTooltipNote: String? = nil) -> [WidgetDescriptor] {
        let descriptors: [WidgetDescriptor] = [
            .combined(id: "\(provider.id).today", provider: provider, title: "Today", isUsagePeriod: true),
            .combined(id: "\(provider.id).yesterday", provider: provider, title: "Yesterday", isUsagePeriod: true),
            .combined(id: "\(provider.id).last30", provider: provider, title: "Last 30 Days", isUsagePeriod: true)
        ]
        // 전체 집합을 local spend tile로 표시 — Total Spend 카드의 capability·기여 신호.
        return descriptors.map { descriptor in
            var sample = descriptor.sample
            sample.valueTooltipNote = valueTooltipNote
            return WidgetDescriptor(
                id: descriptor.id,
                providerID: descriptor.providerID,
                metricLabel: descriptor.metricLabel,
                sample: sample,
                pinnable: descriptor.pinnable,
                isSpendTile: true,
                limitResources: descriptor.limitResources,
                historyResource: descriptor.historyResource
            )
        }
    }

    /// custom trailing word를 갖는 unbounded dollar balance (예: "$1,503.00 left").
    static func dollarBalance(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: nil, unboundedValueWord: valueWord))
    }

    /// `valueTextOverride`로 provider `.badge` line에서 resolve되는 unbounded count (예: Grok pay-as-you-go).
    static func badge(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: nil))
    }

    /// Usage Trend row — provider `.chart` line 기반 일별 token sparkline.
    /// tray가 chart를 못 그려 pin 불가, 그 외는 일반 Customize metric. `isChart`가 live chart point 렌더 신호.
    static func usageTrend(provider: Provider) -> WidgetDescriptor {
        var sample = WidgetData(title: "Usage Trend", icon: provider.icon, kind: .count, used: 0, limit: nil)
        sample.isChart = true
        return make(id: "\(provider.id).trend", provider: provider, metricLabel: "Usage Trend",
                    sample: sample, pinnable: false)
    }

    private static func make(
        id: String,
        provider: Provider,
        metricLabel: String,
        sample: WidgetData,
        pinnable: Bool = true
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metricLabel,
            sample: sample,
            pinnable: pinnable
        )
    }
}
