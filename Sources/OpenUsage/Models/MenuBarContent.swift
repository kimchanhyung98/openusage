import Foundation

/// pinned metric과 live 값으로 만든 menu-bar strip용 데이터 — resolve·정렬·개수 제한 완료.
/// `groups`는 Text style(1 pinned provider = 1 segment), `bars`는 Bars style(fill 있는 bounded metric 선착 4개), `isEmpty`면 기본 app icon 렌더.
struct MenuBarContent: Equatable {
    /// resolve 완료된 pinned metric 하나.
    struct Metric: Equatable {
        let id: String
        let label: String       // metric label — provider에 metric이 2개일 때 표시
        let value: String       // tray 표시값 — bounded는 "%", unbounded는 raw 값, 없으면 no-data marker
        let fraction: Double     // 0...1 fill — bounded metric에서만 유효 (bars 렌더 근거)
        let isBounded: Bool      // limit 보유 → fill 보유 — bar 렌더 가능 여부
        let hasData: Bool
    }

    /// provider 하나와 순서대로의 pinned metric — Text strip의 segment 하나.
    struct Group: Equatable {
        let providerID: String
        let displayName: String
        let icon: IconSource
        let metrics: [Metric]
    }

    /// Text style용 provider group (Customize 순서).
    /// 실데이터 있는 metric만 포함, 전부 데이터 없는 provider는 icon째 제외 — strip에 "—" placeholder 없음.
    let groups: [Group]
    /// Bars style용 bounded metric(fill 보유) — 순서대로 평탄화, 최대 4개.
    let bars: [Metric]
    /// 현재 strip 값이 시간만으로 무효화되는 가장 이른 시각. 상태 아이템의 1회성 재렌더 예약용.
    var nextInvalidation: Date? = nil

    /// pin 없음·pinned provider 전부 비활성·데이터 있는 pin 없음 — menu bar가 app icon으로 fallback.
    var isEmpty: Bool { groups.isEmpty }

    /// 렌더된 strip 이미지의 VoiceOver 요약 (예: "Claude Session 41%, Weekly 12%").
    var accessibilityText: String {
        groups.map { group in
            let metrics = group.metrics.map { "\($0.label) \($0.value)" }.joined(separator: ", ")
            return "\(group.displayName) \(metrics)"
        }
        .joined(separator: "; ")
    }
}

@MainActor
enum MenuBarContentBuilder {
    /// compact style이 렌더하는 최대 bar 수.
    static let maxBars = 4

    /// pinned provider group을 menu-bar content로 resolve.
    /// `groups`는 정렬·비활성 제외 완료(`LayoutStore.pinnedGroups`), `data`는 live `WidgetData` resolver, `title`은 카드 title resolver.
    /// pin은 membership — 데이터 없는 metric은 탈락, 데이터 있는 pin 없는 provider는 icon째 제외.
    static func build(
        groups: [ProviderMetrics],
        data: (WidgetDescriptor) -> WidgetData,
        title: (Provider) -> String = { $0.displayName },
        now: Date = Date()
    ) -> MenuBarContent {
        var invalidationDates: [Date] = []
        let resolvedGroups = groups.compactMap { group -> MenuBarContent.Group? in
            let metrics = group.metrics.compactMap { descriptor -> MenuBarContent.Metric? in
                let widgetData = data(descriptor)
                let metric = resolve(descriptor, widgetData, at: now)
                guard metric.hasData else { return nil }
                if let deadline = widgetData.forecastDeadline, deadline > now {
                    invalidationDates.append(deadline)
                }
                return metric
            }
            guard !metrics.isEmpty else { return nil }
            return MenuBarContent.Group(
                providerID: group.provider.id,
                displayName: title(group.provider),
                icon: group.provider.icon,
                metrics: metrics
            )
        }
        // bars는 bounded metric 전부 대상 — fill 없는 unbounded 값은 제외.
        let bars = resolvedGroups
            .flatMap(\.metrics)
            .filter(\.isBounded)
            .prefix(maxBars)
        return MenuBarContent(
            groups: resolvedGroups,
            bars: Array(bars),
            nextInvalidation: invalidationDates.min()
        )
    }

    private static func resolve(
        _ descriptor: WidgetDescriptor,
        _ data: WidgetData,
        at now: Date
    ) -> MenuBarContent.Metric {
        let data = data.presented(at: now)
        return MenuBarContent.Metric(
            id: descriptor.id,
            label: trayLabel(descriptor.metricLabel),
            value: data.menuBarValue,
            fraction: data.fraction,
            isBounded: data.isBounded,
            hasData: data.hasData
        )
    }

    /// tray 전용 label 축약(dashboard는 전체 이름 유지) — 긴 시간 window metric은 한 글자로, 미지정 label은 통과.
    private static func trayLabel(_ metricLabel: String) -> String {
        switch metricLabel.lowercased() {
        case "today": return "T"
        case "yesterday": return "Y"
        case "last 30 days": return "M"
        default: return metricLabel
        }
    }
}
