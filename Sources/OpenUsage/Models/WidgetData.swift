import Foundation

/// tile이 metric 하나를 렌더하는 데 필요한 전부.
/// `limit` 있으면 capsule meter row, 없으면 unbounded 금액 → 우측 정렬 텍스트 한 줄.
struct WidgetData: Hashable {
    static let localEstimateNote = "Estimated locally, so it may be off"
    static let cursorUsageHistoryNote = "From your Cursor usage history."
    static let noDataHeadline = "—"
    static let noDataSubtitle = "No data"

    let title: String          // 예: "Claude 5h"
    let icon: IconSource
    let kind: MetricKind
    let used: Double
    var limit: Double?         // nil이면 unbounded (number tile) — `.values` line resolve 시 해제
    var countSuffix: String?   // 예: "credits"
    var valuePrefix: String?   // 예: forecast의 "~"
    var displayMode: WidgetDisplayMode = .used
    /// 전역 relative/absolute reset 표시 — `WidgetDataStore`가 stamp.
    var resetDisplayMode: ResetDisplayMode = .relative
    /// 전역 "always show pacing" opt-in — `WidgetDataStore`가 stamp.
    /// on이면 blue row에도 even-pace tick·projection 문구 표시 — yellow/red는 reset window 있으면 항상 tick 표시.
    var alwaysShowPacing: Bool = false
    /// quota가 아닌 공개 reset forecast meter — Used/Left·pace·quota 알림 의미에서 분리.
    var isForecast: Bool = false
    var forecastDeadline: Date?
    var resetsAt: Date?
    /// row hover tooltip에 표시할 미래 expiry 시각들 (Codex reset credit — 가용 credit당 1개). 다른 row는 빈 배열.
    /// raw `Date` 유지 — tooltip이 live format하며 전역 relative/absolute mode 준수 (`expiryTooltip`).
    var expiriesAt: [Date] = []
    /// Codex rate-limit-reset-credits row 표시 descriptor opt-in.
    /// 설정 시 값 column hover로 resets popover 표시 — `expiriesAt`이 빈 "0 available"에서도 접근 유지.
    var showsResetExpiries: Bool = false
    /// pricing source가 가격 못 매긴 이번 기간 사용 model 이름들 — 합계에서 제외되어 수치 과소 가능.
    /// label 경고 triangle과 hover 목록의 근거. 다른 row는 빈 배열.
    var unknownModels: [String] = []
    /// Today / Yesterday / Last 30 Days hover popover용 기간 단위 model spend/tokens — 비-spend row·model 데이터 없는 기간은 nil.
    var modelBreakdown: ModelUsageBreakdown?
    var periodDurationMs: Int?
    var valueTextOverride: String?
    var subtitleOverride: String?
    var limitNoun: String?     // dollar limit 뒤 단어 (기본 "limit")
    /// unbounded row의 고정 trailing word (예: "left", "spent") — 설정 시 전역 left/used mode 단어 대체.
    var unboundedValueWord: String?
    /// local 추정 tile의 source/disclaimer note — 값 쪽 hover에 렌더, label은 inert 유지.
    var infoNote: String?
    /// Cursor spend history 같은 value row의 source note.
    var valueTooltipNote: String?
    /// 실제 provider metric의 backing 여부 — false면 view가 template 숫자 대신 "No data" 표시.
    var hasData: Bool = true
    /// unbounded `.values` row의 raw 숫자 (meter는 빈 배열) — view가 렌더 시점에 format (`unboundedDetail`).
    var values: [MetricValue] = []
    /// `values` 중 렌더 대상 — descriptor factory가 설정, provider row 하나로 여러 tile 지원.
    var selection: ValueSelection = .all
    /// Today / Yesterday / Last 30 Days spend tile 전용 true — 시간 window 누적이라 all-zero가 "미사용" 의미.
    /// balance/availability row의 0은 고갈이지 idle 아님 — false 유지로 "No usage in this period" note 제외.
    var isUsagePeriod: Bool = false
    /// unbounded count의 menu-bar 값 뒤에 붙는 tray 전용 단위 단어 (예: "2 resets") — bare 값 tile은 nil.
    /// descriptor가 설정 — tile rename에도 suffix 유지 (title 매칭 대체).
    var traySuffix: String?
    /// 미사용 시 "Not started"로 읽히는 session-window meter (Claude/Antigravity 5시간 pool).
    /// descriptor opt-in — hardcoded widget-ID 목록 대체, `WidgetDataStore.resolve`로 전달.
    var isSessionWindow: Bool = false
    /// Usage Trend row 표시 — true면 view가 값 layout 대신 sparkline 렌더.
    /// `chartPoints`는 일별 point(다른 tile은 빈 배열), `chartNote`는 hover에 표시할 source 문구.
    var isChart: Bool = false
    var chartPoints: [MetricChartPoint] = []
    var chartNote: String?
    /// 이 row 데이터의 출처 provider(카드) — `WidgetDataStore.data(for:)`가 stamp, per-card action의 key.
    /// direct fixture(preview, share render)에서는 nil — 해당 action 비활성.
    var providerID: String?

    var isBounded: Bool { limit != nil }
    var isQuotaMeter: Bool { isBounded && !isForecast }

    var hasModelBreakdown: Bool {
        hasData && isUsagePeriod && !(modelBreakdown?.models.isEmpty ?? true)
    }

    var selectedValues: [MetricValue] { selection.apply(to: values) }

    var displayedValue: Double {
        guard !isForecast, displayMode == .remaining, let limit else { return used }
        return max(0, limit - used)
    }

    /// ring fill 0...1 — headline과 같은 반올림 값 사용, "0%" 표시 시 빈 ring 보장.
    /// display mode 의존 (`remaining/limit` 또는 `used/limit`) — mode 무관 remaining은 `remainingFraction` 사용.
    var fraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max(roundedDisplayValue / limit, 0), 1)
    }

    /// limit 대비 잔여 비율 0...1 — used/remaining 표시 mode와 무관.
    /// quota notification의 "under 10% remaining" 판정 근거.
    var remainingFraction: Double {
        guard let limit, limit > 0 else { return 0 }
        return min(max((limit - used) / limit, 0), 1)
    }

    /// meter fill 색상의 severity band (`MeterState.severity` 참조).
    enum MeterSeverity: Hashable {
        case neutral, normal, warning, critical
    }

    /// meter의 전체 시각 상태 — `meterState(now:)`에서 한 번 파생, bar 색·tick·경고 문구의 단일 근거.
    /// 우선순위(높은 순): no data → spent → live pace 판정 → 절대 level band.
    enum MeterState: Hashable {
        /// backing metric 없음 — gray, 빈 track, 문구 없음.
        case noData
        /// 잔여가 headline 표시 정밀도에서 0으로 반올림되는 소진 상태 — red, flame + "Limit reached".
        /// pace 판정보다 우선 — 눈에 비어 보이는 bar는 더 차분한 색 불가.
        case spent
        /// reset 전 소진 예상 또는 여유 없이 limit 정확 착지 예상 — red, flame + run-out 시각.
        /// `eta`는 run-out이 reset과 사실상 겹치거나 예상 여유가 0%로 반올림될 때 nil — flame 단독 표시.
        /// `projectedFraction`(예상 기말 사용 ÷ limit)은 tooltip의 overage 문구 근거.
        case runningOut(eta: String?, projectedFraction: Double)
        /// 마지막 10% 안 착지 예상이되 여유 1% 이상 — amber, "~N% spare" note.
        /// 여유가 0%로 반올림되면 `runningOut`으로 승격 — amber가 "~0% spare"로 읽히는 일 없음.
        case closeToLimit(spare: String, projectedFraction: Double)
        /// 여유 ≥10%로 마칠 예상 — blue. 기본 장식 없음, "always show pacing" on이면 projection 문구 표시.
        case healthy(projectedFraction: Double)
        /// pace 대상 reset window 없음 — 사용 비율의 절대 level band로 색 결정, 문구 없음.
        case level(MeterSeverity)

        /// bar fill severity — `noData`는 nil (track gray 유지).
        var severity: MeterSeverity? {
            switch self {
            case .noData: return nil
            case .spent, .runningOut: return .critical
            case .closeToLimit: return .warning
            case .healthy: return .normal
            case .level(let severity): return severity
            }
        }

        /// bar·spare note·flame이 공유하는 hover tooltip — reset 시점 pace 착지 예상 수치.
        /// blue → 예상 여유, amber → 예상 사용률, red → 초과율(limit 정확 착지는 "~100% used at reset").
        /// pace 서사 없는 상태(no data, 절대 band)는 nil, spent는 "Limit reached".
        var tooltip: String? {
            switch self {
            case .noData, .level: return nil
            case .spent: return "Limit reached"
            case .healthy(let projectedFraction):
                let left = Int(((1 - projectedFraction) * 100).rounded())
                return "~\(left)% left at reset"
            case .closeToLimit(_, let projectedFraction):
                let used = Int((projectedFraction * 100).rounded())
                return "~\(used)% used at reset"
            case .runningOut(_, let projectedFraction):
                guard projectedFraction > 1 else { return "~100% used at reset" }
                // 1% floor — 근소 초과가 "~0% over limit"로 읽히는 것 방지.
                let over = max(1, Int(((projectedFraction - 1) * 100).rounded()))
                return "~\(over)% over limit at reset"
            }
        }

    }

    private var roundedDisplayValue: Double {
        roundedAtDisplayPrecision(displayedValue)
    }

    /// kind별 headline 표시 정밀도로 반올림 (whole percent / 소수 1자리 count / cent).
    /// "0%"로 읽히는 값은 0으로 등록 — meter geometry·spent 판정과 인쇄 숫자의 불일치 방지.
    private func roundedAtDisplayPrecision(_ value: Double) -> Double {
        switch kind {
        case .percent: return value.rounded()
        case .count: return (value * 10).rounded() / 10
        case .dollars: return (value * 100).rounded() / 100
        }
    }

    /// menu bar·unbounded row의 primary 값 문자열.
    /// backing metric 없으면 no-data marker 반환 — placeholder sample 숫자가 실측처럼 인쇄되는 일 차단.
    var valueText: String {
        guard hasData else { return Self.noDataHeadline }
        if let valueTextOverride { return valueTextOverride }
        // `.values` row의 primary는 첫 selected 값 — meter는 bounded/`used` format으로 fall through.
        if let first = selectedValues.first {
            return (valuePrefix ?? "") + MetricFormatter.number(first.number, kind: first.kind, style: .row)
        }
        return (valuePrefix ?? "") + format(displayedValue)
    }

    /// menu-bar(tray) 표시값 — bounded는 단위 유지 + 전역 Used/Left mode 반영, unbounded는 popover와 같은 formatter로 압축.
    /// 숫자 없는 status badge(예: Grok "Disabled")는 "0" 대신 text 표시.
    var menuBarValue: String {
        guard hasData else { return valueText }
        if let limit, limit > 0 {
            if kind == .percent {
                // bounded 중 percent만 tray 백분율로 축약 — 양끝 clamp로 "-5%"/"105%" 방지.
                let percent = min(100, max(0, Int((displayedValue / limit * 100).rounded())))
                return "\(percent)%"
            }
            return MetricFormatter.number(displayedValue, kind: kind, style: .tray)
        }
        if let first = selectedValues.first {
            if let traySuffix, first.kind == .count {
                return "\(MetricFormatter.number(first.number, kind: .count, style: .tray)) \(traySuffix)"
            }
            return MetricFormatter.string(for: first, style: .tray)
        }
        if let valueTextOverride { return valueTextOverride }
        let number = MetricFormatter.number(displayedValue, kind: kind, style: .tray)
        if kind == .count, let countSuffix { return "\(number) \(countSuffix)" }
        return number
    }

    var boundedHeadline: String {
        if let valueTextOverride {
            return valueTextOverride
        }
        if isForecast {
            return "\(valueText) chance"
        }
        // 단위는 boundedSubtitle 담당 — "Used"/"Left" 단어의 단일 출처는 `WidgetDisplayMode.label`.
        return "\(valueText) \(displayMode.label.lowercased())"
    }

    /// bounded headline 아래 subtitle (reset 시점 또는 limit context).
    var boundedSubtitle: String? {
        if let subtitleOverride {
            return subtitleOverride
        }
        if isForecast, let forecastDeadline {
            return Formatters.resetWatchDeadlineLabel(at: forecastDeadline)
        }
        if let resetLabel {
            return resetLabel
        }
        // 정확한 reset 일시 없는 cycle형 metric은 reset 주기 표시.
        if let periodDurationMs,
           let duration = Formatters.compactDuration(TimeInterval(periodDurationMs) / 1000) {
            return "Resets in \(duration)"
        }
        switch kind {
        case .percent:
            return nil
        case .dollars:
            // bounded dollar의 보조 줄은 "$<limit> limit" — "of" 없음, limit이 정수 dollar가 아닐 때만 cents.
            guard let limit else { return nil }
            let digits = limit.rounded() == limit ? 0 : 2
            let amount = Formatters.currency(limit, fractionDigits: digits)
            return "\(amount) \(limitNoun ?? "limit")"
        case .count:
            // 단위(예: "credits")로 bounded count와 일반 balance 구분.
            return countSuffix
        }
    }

    var headline: String {
        guard hasData else { return Self.noDataHeadline }
        return isBounded ? boundedHeadline : valueText
    }

    /// unbounded row(우측 정렬, bar 없음)의 설명 줄 — "<value> <word>".
    /// word는 `unboundedValueWord` 우선, 없으면 전역 left/used mode 단어.
    var unboundedDetail: String {
        guard hasData else { return Self.noDataSubtitle }
        if let valueTextOverride { return valueTextOverride }
        let selected = selectedValues
        if !selected.isEmpty {
            // 단일 값: 단독 dollar는 widget trailing word, 그 외는 자체 unit label — 복수 값은 " · "로 결합.
            if selected.count == 1 {
                let value = selected[0]
                if value.kind == .dollars, let word = unboundedValueWord {
                    return "\(MetricFormatter.number(value.number, kind: .dollars, style: .row)) \(word)"
                }
                return MetricFormatter.string(for: value, style: .row)
            }
            return selected.map { MetricFormatter.string(for: $0, style: .row) }.joined(separator: " · ")
        }
        // typed 값 없는 unbounded row의 fallback: "<value> <suffix> <word>".
        let word = unboundedValueWord ?? displayMode.label.lowercased()
        if kind == .count, let countSuffix {
            return "\(valueText) \(countSuffix) \(word)"
        }
        return "\(valueText) \(word)"
    }

    /// reset-credit expiry의 색 band — 평시 blue, 1주 미만 amber, 48시간 미만 red.
    /// 지난 expiry는 다음 refresh에서 목록에서 빠질 때까지 critical 유지.
    static let expiryWarningWindow: TimeInterval = 7 * 24 * 60 * 60
    static let expiryCriticalWindow: TimeInterval = 48 * 60 * 60

    /// 잔여 초 기준 expiry severity band — 48h 미만 red, 1주 미만 amber, 그 외 blue.
    /// row status dot과 resets popover per-credit dot이 공유 — 같은 credit이 두 곳에서 다른 색 불가.
    static func expirySeverity(secondsRemaining: TimeInterval) -> MeterSeverity {
        if secondsRemaining <= expiryCriticalWindow { return .critical }
        if secondsRemaining <= expiryWarningWindow { return .warning }
        return .normal
    }

    /// reset-credit expiry 보유 row의 시각 status — popover 30s tick마다 재계산.
    func expirySeverity(now: Date = Date()) -> MeterSeverity? {
        guard hasData, let soonest = expiriesAt.min() else { return nil }
        return Self.expirySeverity(secondsRemaining: soonest.timeIntervalSince(now))
    }

    /// `showsResetExpiries` row의 가용 reset-credit 수 ("N available" 수치).
    /// "credit 없음"(빈 상태)과 "expiry 목록만 없는 credit"(usage-body fallback — `expiriesAt` 빈 채 count만 존재) 구분용.
    var resetCreditCount: Int {
        Int((selectedValues.first?.number ?? 0).rounded(.down))
    }

    /// expiry 보유 row(Codex reset-credit)의 hover tooltip — credit별 reset 만료 시점, 전역 relative/absolute mode 준수.
    /// 1개면 단문, 복수면 header 아래 번호 목록 — expiry 없으면 nil, 비-reset row는 figures tooltip으로 fall through.
    var expiryTooltip: String? {
        guard hasData, !expiriesAt.isEmpty else { return nil }
        let now = Date()
        let sorted = expiriesAt.sorted()
        if sorted.count == 1 {
            return Formatters.deadlineLabel("Reset expires", at: sorted[0], mode: resetDisplayMode, now: now)
        }
        let entries = sorted.enumerated().compactMap { index, date -> String? in
            Formatters.whenLabel(at: date, mode: resetDisplayMode, now: now).map { "\(index + 1). \($0)" }
        }
        guard !entries.isEmpty else { return nil }
        // header가 동사 담당 — "in"은 relative duration에만 적합 (absolute entry는 자체 완결).
        let header = resetDisplayMode == .relative ? "Resets expire in:" : "Resets expire:"
        return ([header] + entries).joined(separator: "\n")
    }

    var hasUnknownModels: Bool {
        hasData && !unknownModels.isEmpty
    }

    /// unknown-model 경고 triangle의 hover 문구 — 단·복수 header + 미가격 model별 한 줄.
    /// 전 model 가격 계산된 경우 nil — triangle·tooltip 비표시.
    var unknownModelTooltip: String? {
        guard hasUnknownModels else { return nil }
        let header = unknownModels.count == 1 ? "Unknown model found" : "Unknown models found"
        return ([header] + unknownModels.map { "- \($0)" }).joined(separator: "\n")
    }

    var unboundedSubtitle: String? {
        guard hasData else { return nil }
        return subtitleOverride
    }

    /// row hover tooltip용 전체 값 — 압축 row가 줄인 정확한 숫자.
    /// 축약된 값도 source note도 없으면 nil — 불필요한 tooltip 방지.
    var unboundedTooltip: String? {
        guard hasData else { return nil }
        let selected = selectedValues
        guard selected.contains(where: { abs($0.number) >= 1000 }) || unboundedTooltipNote != nil else { return nil }
        return selected.map { MetricFormatter.string(for: $0, style: .full) }.joined(separator: " · ")
    }

    /// unbounded row 값(및 expiry 경고 icon)의 hover text — reset-credit row는 per-credit expiry breakdown, 그 외 정확한 figures + source note.
    /// 축약 없고 note 없는 non-zero row는 nil.
    var unboundedValueTooltip: String? {
        // reset-credit row는 expiry breakdown 우선 — 작은 count라 figures tooltip 없음.
        if let expiry = expiryTooltip { return expiry }
        if isZeroUsage && isUsagePeriod {
            return (["No usage in this period"] + [unboundedTooltipNote].compactMap { $0 }).joined(separator: "\n")
        }
        if let figures = unboundedTooltip {
            return ([figures] + [unboundedTooltipNote].compactMap { $0 }).joined(separator: "\n")
        }
        // "no usage" note는 spend 기간에만 적합 — balance row의 0은 고갈이므로 note 없음.
        return nil
    }

    private var unboundedTooltipNote: String? {
        infoNote ?? valueTooltipNote
    }

    /// zero-usage 기간 — 데이터 있고 selected 값 전부 0.
    /// "no data"·소액 사용과 구분 — figures 대신 "no usage" note 표시 근거.
    var isZeroUsage: Bool {
        guard hasData else { return false }
        let selected = selectedValues
        return !selected.isEmpty && selected.allSatisfy { $0.number == 0 }
    }

    var resetLabel: String? {
        guard let resetsAt else { return nil }
        return Formatters.resetRelativeLabel(until: resetsAt)
    }

    private func format(_ value: Double) -> String {
        MetricFormatter.number(value, kind: kind, style: .full)
    }
}

// MARK: - Pace (meter state)

extension WidgetData {
    /// pacing 입력값 — reset window가 알려진 bounded metric에서만 존재.
    /// nil이면 live pace 판정 생략 — bar는 절대 level band로 fallback.
    private var paceContext: (limit: Double, resetsAt: Date, period: TimeInterval)? {
        guard hasData, !isForecast, let limit, limit > 0, let resetsAt,
              let periodDurationMs, periodDurationMs > 0 else { return nil }
        return (limit, resetsAt, TimeInterval(periodDurationMs) / 1000)
    }

    /// `now` 기준 meter의 전체 시각 상태 — row 색·amber tick·경고 문구의 단일 근거.
    /// 우선순위: no data → spent(잔여가 표시 정밀도에서 0) → live pace 판정(blue/amber/red) → 절대 level band(80% yellow, 90% red).
    /// 모든 band는 표시 fraction이 아닌 사용 비율 기준 — Used/Left toggle에 색·문구 불변.
    func meterState(now: Date = Date()) -> MeterState {
        guard hasData, let limit, limit > 0 else { return hasData ? .level(.normal) : .noData }
        if isForecast { return forecastLevelState(chance: used, limit: limit) }
        if roundedAtDisplayPrecision(limit - used) <= 0 { return .spent }
        // "Not started" session은 pace 대상 없음 — projection 문구·tick 없는 차분한 bar로 표시.
        if isFreshSessionWindow(now: now) { return absoluteLevelState(used: used, limit: limit) }

        if let ctx = paceContext,
           let result = Pace.evaluate(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                      periodDuration: ctx.period, now: now) {
            switch result.status {
            case .ahead:
                return .healthy(projectedFraction: result.projectedUsage / ctx.limit)
            case .onTrack:
                // whole-percent 1%가 limit 정확 착지 가능 — `.behind`와 같은 near-empty 보호 적용.
                guard used / ctx.limit >= 0.05 else { return absoluteLevelState(used: used, limit: limit) }
                let projected = result.projectedUsage / ctx.limit
                let spare = Int(((1 - projected) * 100).rounded())
                guard spare >= 1 else { return .runningOut(eta: nil, projectedFraction: projected) }
                return .closeToLimit(spare: "~\(spare)% spare", projectedFraction: projected)
            case .behind:
                // coarse whole-percent meter는 window 초반 허위 blow-out을 projection — used 5% 미만이면 projection 불신, 절대 level band 사용.
                guard used / ctx.limit >= 0.05 else { return absoluteLevelState(used: used, limit: limit) }
                let eta = Pace.secondsToRunOut(used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                                               periodDuration: ctx.period, now: now)
                    .flatMap { Formatters.deadlineLabel("Limit", at: now.addingTimeInterval($0),
                                                        mode: resetDisplayMode, now: now) }
                return .runningOut(eta: eta, projectedFraction: result.projectedUsage / ctx.limit)
            }
        }

        return absoluteLevelState(used: used, limit: limit)
    }

    /// 신뢰할 pace projection 없을 때 사용 비율로 색 결정 — 80% yellow, 90% red, 그 외 blue.
    /// projection 문구·tick 없는 단순 level 판독.
    private func absoluteLevelState(used: Double, limit: Double) -> MeterState {
        let percentUsed = (min(max(used / limit, 0), 1) * 100).rounded()
        if percentUsed >= 90 { return .level(.critical) }
        if percentUsed >= 80 { return .level(.warning) }
        return .level(.normal)
    }

    /// Reset Watch 확률 전용 단계 — 일반 quota의 80/90 절대 band와 분리.
    private func forecastLevelState(chance: Double, limit: Double) -> MeterState {
        let percent = (min(max(chance / limit, 0), 1) * 100).rounded()
        if percent >= 70 { return .level(.critical) }
        if percent >= 60 { return .level(.warning) }
        if percent >= 40 { return .level(.normal) }
        return .level(.neutral)
    }

    /// bar 위 even-pace tick 위치 0...1, 숨김이면 nil — reset window 경과 비율을 fill과 같은 관점으로 표시.
    /// yellow/red pace 상태는 항상 표시, blue는 `alwaysShowPacing`일 때만 — spent·no-data·window 없는 row는 미표시.
    func paceTick(for state: MeterState, now: Date = Date()) -> Double? {
        switch state {
        case .spent, .noData, .level: return nil
        case .healthy: guard alwaysShowPacing else { return nil }
        case .closeToLimit, .runningOut: break
        }
        guard let ctx = paceContext else { return nil }
        let windowStart = ctx.resetsAt.addingTimeInterval(-ctx.period)
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= Pace.minimumElapsed(periodDuration: ctx.period), now < ctx.resetsAt else { return nil }
        let elapsedFraction = min(max(elapsed / ctx.period, 0), 1)
        return displayMode == .remaining ? 1 - elapsedFraction : elapsedFraction
    }

    /// bounded primary row의 trailing text — 우선순위는 `boundedSubtitle`과 동일하되 reset은 `resetDisplayMode` 반영.
    /// session row는 rolling window 시작 전 "Not started" 표시.
    func boundedTrailingText(now: Date = Date()) -> String? {
        guard hasData else { return Self.noDataSubtitle }
        if let subtitleOverride { return subtitleOverride }
        if isForecast, let forecastDeadline {
            return Formatters.resetWatchDeadlineLabel(at: forecastDeadline)
        }
        if isFreshSessionWindow(now: now) { return "Not started" }
        if let resetsAt {
            return resetDisplayMode == .absolute
                ? Formatters.resetAbsoluteLabel(at: resetsAt, now: now)
                : Formatters.resetRelativeLabel(until: resetsAt, now: now)
        }
        return boundedSubtitle // 주기/limit/suffix context — flip 대상 아님
    }

    /// session meter(Claude/Antigravity) 전용 "Not started" 판정 — 현재 window에서 사용 0 기준.
    /// window-timing이 아닌 frozen usage(`used == 0`)가 snapshot 일관 신호 — headline과 label의 분리 방지.
    /// `now < resetsAt` 조건 유지 — reset 경과 후 stale snapshot은 일반 countdown으로 fallback.
    func isFreshSessionWindow(now: Date = Date()) -> Bool {
        guard isSessionWindow, hasData, limit != nil, let resetsAt, used <= 0 else { return false }
        return now < resetsAt
    }

    /// bounded row trailing text가 클릭 가능한 reset countdown인지 여부 — limit/suffix context·fresh window·reset 없음은 false.
    func hasResetLabel(now: Date = Date()) -> Bool {
        hasData && !isForecast && subtitleOverride == nil && resetsAt != nil && !isFreshSessionWindow(now: now)
    }

    /// "Not started" trailing label의 hover 설명 문구 — 첫 메시지 전에는 countdown 없음.
    static let freshSessionTooltip = "Sessions start after you send your first message."

    /// reset label의 hover tooltip — 현재 표시와 반대 format.
    /// fresh("Not started") session은 reset 시각 대신 자체 설명 표시.
    func resetTooltip(now: Date = Date()) -> String? {
        if isFreshSessionWindow(now: now) { return Self.freshSessionTooltip }
        guard hasResetLabel(now: now), let resetsAt else { return nil }
        return resetDisplayMode == .absolute
            ? Formatters.resetRelativeLabel(until: resetsAt, now: now)
            : Formatters.resetAbsoluteLabel(at: resetsAt, now: now)
    }

    /// bounded headline이 flip 가능한 Used/Left 표시인지 여부 — unbounded·override·no-data row는 false.
    var hasMeterStyleToggle: Bool {
        hasData && isQuotaMeter && valueTextOverride == nil
    }

    /// bounded headline의 hover tooltip — 현재와 반대 meter style (예: "95% left" → "5% used").
    var meterStyleTooltip: String? {
        guard hasMeterStyleToggle, let limit else { return nil }
        let opposite = displayMode == .remaining ? used : max(0, limit - used)
        let word = (displayMode == .remaining ? WidgetDisplayMode.used : .remaining).label.lowercased()
        return "\((valuePrefix ?? "") + format(opposite)) \(word)"
    }

    /// forecast의 의미상 deadline을 transport/cache freshness보다 우선 적용.
    func presented(at date: Date = Date()) -> WidgetData {
        guard isForecast, let forecastDeadline, date >= forecastDeadline else { return self }
        var copy = self
        copy.hasData = false
        return copy
    }
}

extension WidgetData {
    /// neighbor 기반 condensing 규칙의 단일 정의 — 한 run 안에서 text-only row(`!isBounded`) 바로 아래의 text-only row offset.
    /// run은 expand caret을 넘지 않음 — caller가 경계에서 분할해 segment별 scan.
    /// dashboard는 offset을 descriptor ID로, share-card export는 flat index로 매핑.
    static func condensedTextRowOffsets(in rows: [WidgetData]) -> Set<Int> {
        var offsets = Set<Int>()
        for index in rows.indices.dropFirst() where !rows[index - 1].isBounded && !rows[index].isBounded {
            offsets.insert(index)
        }
        return offsets
    }
}
