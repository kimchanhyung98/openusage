import Foundation

/// Total Spend 카드가 표시하는 spend period — `SpendTileMapper`의 per-provider spend tile 3종과 대응, line 라벨이 lookup key.
enum TotalSpendPeriod: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last30 = "Last 30 Days"

    var id: String { rawValue }

    /// 이 period가 provider 전반에서 합산하는 metric-line 라벨 — 현재 raw value와 동일하나 두 의미가 분기할 수 있어 별도 accessor 유지.
    var lineLabel: String { rawValue }

    /// period 스위처용 compact segment 제목 — "Last 30 Days"는 320pt popover의 3분할에 안 들어감.
    var shortLabel: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .last30: "30 Days"
        }
    }
}

/// Total Spend 카드의 ring·center·legend가 보여줄 수량. aggregator는 달러·token을 항상 함께 수집해 모드 전환에 재스캔 없음.
/// raw value `apiSpend`는 기존 설치의 저장된 Cost 선택 보존용.
enum TotalSpendMetric: String, CaseIterable, Identifiable, Sendable {
    /// 메뉴 순서는 선언 순서: Cost → Cost/MTok → Tokens. 기본값은 Cost.
    case cost = "apiSpend"
    case costPerMtok
    case tokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cost: "Cost"
        case .costPerMtok: "Cost/MTok"
        case .tokens: "Tokens"
        }
    }

    /// 선택된 period에 해당 metric의 provider가 없을 때의 empty-state 문구.
    var emptyMessage: String {
        switch self {
        case .cost: "No cost data for this period"
        case .costPerMtok: "No cost-per-token data for this period"
        case .tokens: "No token data for this period"
        }
    }

    /// 달러 기반 모드는 기여자의 spend가 imputed일 때 local-estimate 노트 상속 가능.
    var usesDollarEstimateNote: Bool {
        switch self {
        case .cost, .costPerMtok: true
        case .tokens: false
        }
    }
}

/// period 총계에 대한 provider 한 곳의 기여 — 같은 spend line의 달러·token과 달러의 local estimate 여부.
struct TotalSpendSlice: Identifiable, Equatable {
    let provider: Provider
    /// 집계 호출자가 단일 name resolver로 해석한 카드 제목 — legend·순위 tie-break·share-card export가 같은 live 이름 표시.
    let title: String
    let amountUSD: Double
    let tokenCount: Double
    let estimated: Bool

    var id: String { provider.id }

    /// 이 provider 단독의 dollars per million tokens — 한쪽이라도 없으면 `nil`.
    var costPerMtok: Double? {
        guard amountUSD > 0, tokenCount > 0 else { return nil }
        return (amountUSD / tokenCount) * 1_000_000
    }
}

/// 선택된 metric 하의 그리기 준비된 provider 기여 — ring 크기·legend 순위를 정하는 amount, 표시는 `MetricFormatter` 경유.
struct TotalSpendProjectedSlice: Identifiable, Equatable {
    let provider: Provider
    /// 이미 해석된 카드 제목(`TotalSpendSlice.title` 참고) — legend가 렌더하는 값.
    let title: String
    let displayAmount: Double
    let estimated: Bool

    var id: String { provider.id }
}

/// 한 metric 하의 period 교차 provider 총계 — 순위 매겨진 slice, center 값, estimate flag.
struct TotalSpendProjection: Equatable {
    let metric: TotalSpendMetric
    let slices: [TotalSpendProjectedSlice]
    let centerValue: Double
    let isEstimated: Bool

    var isEmpty: Bool { slices.isEmpty }
}

/// period의 교차 provider raw 총계 — 달러/token을 기여한 모든 spend-capable provider. 표시(포함/순위/center)는 `projection(for:)` 담당.
struct TotalSpend: Equatable {
    let period: TotalSpendPeriod
    let slices: [TotalSpendSlice]

    var totalUSD: Double { slices.reduce(0) { $0 + $1.amountUSD } }
    var totalTokens: Double { slices.reduce(0) { $0 + $1.tokenCount } }
    /// 기여자 하나라도 달러가 locally imputed면 합산 숫자는 estimate.
    var isEstimated: Bool { slices.contains(where: \.estimated) }
    /// raw 저장 비어 있음 — 이 period에 달러·token을 가진 provider 없음.
    var isEmpty: Bool { slices.isEmpty }

    /// 제목 메뉴에서 선택된 metric의 필터·순위·center 값 계산.
    func projection(for metric: TotalSpendMetric) -> TotalSpendProjection {
        let included: [(slice: TotalSpendSlice, display: Double)] = slices.compactMap { slice in
            switch metric {
            case .cost:
                guard slice.amountUSD > 0 else { return nil }
                return (slice, slice.amountUSD)
            case .tokens:
                guard slice.tokenCount > 0 else { return nil }
                return (slice, slice.tokenCount)
            case .costPerMtok:
                guard let rate = slice.costPerMtok else { return nil }
                return (slice, rate)
            }
        }

        let ranked = included.sorted { lhs, rhs in
            if lhs.display != rhs.display { return lhs.display > rhs.display }
            return lhs.slice.title.localizedStandardCompare(rhs.slice.title) == .orderedAscending
        }

        let projected = ranked.map {
            TotalSpendProjectedSlice(
                provider: $0.slice.provider,
                title: $0.slice.title,
                displayAmount: $0.display,
                estimated: $0.slice.estimated
            )
        }

        let center: Double
        let estimated: Bool
        switch metric {
        case .cost:
            center = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            estimated = ranked.contains { $0.slice.estimated }
        case .tokens:
            center = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            estimated = false
        case .costPerMtok:
            let usd = ranked.reduce(0) { $0 + $1.slice.amountUSD }
            let tokens = ranked.reduce(0) { $0 + $1.slice.tokenCount }
            center = tokens > 0 ? (usd / tokens) * 1_000_000 : 0
            estimated = ranked.contains { $0.slice.estimated }
        }

        return TotalSpendProjection(metric: metric, slices: projected, centerValue: center, isEstimated: estimated)
    }
}

/// per-provider 일일 spend를 하나의 교차 provider 총계로 합산 — 대시보드 Total Spend ring 카드의 데이터 소스.
/// 순수·동기 — 이미 refresh된 `ProviderSnapshot`만 읽고 fetch하지 않음.
/// provider는 period 라벨의 `.values` line에 달러/token이 있을 때만 기여 — idle period는 0이 아니라 제외.
enum TotalSpendAggregator {
    /// `providers` 전반의 한 period 총계 — 표시 순서로 전달 시 tie 유지, metric projection이 재순위.
    /// `title`은 provider별 카드 제목 해석 — live 카드는 account-registry resolver를 넘겨 리네임 반영, 기본값은 baked 이름(테스트용).
    static func total(
        for period: TotalSpendPeriod,
        providers: [Provider],
        snapshots: [String: ProviderSnapshot],
        title: (Provider) -> String = { $0.displayName }
    ) -> TotalSpend {
        let slices = providers.compactMap { provider -> TotalSpendSlice? in
            guard let snapshot = snapshots[provider.id],
                  let line = snapshot.line(label: period.lineLabel),
                  case .values(_, let values, _, _, _, _) = line else { return nil }

            let dollars = values.filter { $0.kind == .dollars }
            let amount = dollars.reduce(0) { $0 + $1.number }
            let tokens = values
                .filter { $0.kind == .count && $0.label == "tokens" }
                .reduce(0) { $0 + $1.number }
            guard amount > 0 || tokens > 0 else { return nil }

            return TotalSpendSlice(
                provider: provider,
                title: title(provider),
                amountUSD: max(amount, 0),
                tokenCount: max(tokens, 0),
                estimated: dollars.contains(where: \.estimated)
            )
        }
        return TotalSpend(period: period, slices: slices)
    }
}
