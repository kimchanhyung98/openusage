import Foundation

/// 숫자가 표시 텍스트가 되는 유일한 지점 — 모든 surface(popover row, menu-bar strip, hover 상세)가 여기로 포맷.
/// 같은 값이 tray와 popover에서 다르게 읽힐 수 없고, "compact"(12.9K / 3.4M / 1.2B) 정의도 하나.
enum MetricFormatter {
    /// surface별 스타일:
    /// `.tray`는 최단형(정수 달러·축약), `.row`는 축약하되 돈은 소수 두 자리 유지, `.full`은 전체 자릿수 그룹화.
    enum Style {
        case tray
        case row
        case full
    }

    /// 시스템 locale과 무관하게 USD 값이 동일하게 렌더되도록 en_US 고정.
    private static let locale = Locale(identifier: "en_US")

    /// 지정 kind·style의 단위 라벨 없는 숫자.
    static func number(_ value: Double, kind: MetricKind, style: Style) -> String {
        switch kind {
        case .percent:
            // percent는 0...100 bounded 도메인이라 방어적 clamp — 초과분은 meter 상태·색으로 전달, 범위 밖 숫자로는 미표기.
            return "\(Int(ProviderParse.clampPercent(value).rounded()))%"
        case .dollars:
            // tray·row는 네 자리 이상 축약("$1.2M", "$2.1K"); full은 항상 그룹화된 센트 유지.
            if abs(value) >= 1000, style != .full {
                return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            switch style {
            case .tray:
                // $1k 미만 최단형: 정수 달러("$130").
                return "$" + value.formatted(.number.precision(.fractionLength(0)).locale(locale))
            case .row, .full:
                // $1k 미만은 전체 센트 유지.
                return Formatters.currency(value, fractionDigits: 2)
            }
        case .count:
            // tray·row는 천 단위부터 축약, full은 전체 자릿수; 1,000 미만은 소수 한 자리까지 유지해 분수 잔액 보존.
            if style != .full, abs(value) >= 1000 {
                return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
            }
            return value.formatted(.number.precision(.fractionLength(0...1)).locale(locale))
        }
    }

    /// 단위 라벨이 붙은 값(예: "772 credits"). token·dollar·percent 값은 의도적으로 라벨 없이 bare 렌더("56.9M", "$4.08", "95%").
    static func string(for value: MetricValue, style: Style) -> String {
        let text = number(value.number, kind: value.kind, style: style)
        guard let label = value.label, !label.isEmpty else { return text }
        return "\(text) \(label)"
    }

    /// legend·tooltip용 dollars per million tokens — dollar 포맷 + 고정 `/MTok` suffix.
    static func costPerMtok(_ value: Double, style: Style) -> String {
        number(value, kind: .dollars, style: style) + "/MTok"
    }

    /// Total Spend ring 중앙 두 줄 — 짧은 primary 위, unit 아래. live 카드와 share PNG가 공유.
    struct TotalSpendRingCenter: Equatable {
        let primary: String
        let unit: String
    }

    static func totalSpendRingCenter(_ value: Double, metric: TotalSpendMetric) -> TotalSpendRingCenter {
        switch metric {
        case .cost:
            // `$` 유지 — unit 줄은 명확성을 위해 "dollars" 표기.
            return TotalSpendRingCenter(primary: number(value, kind: .dollars, style: .tray), unit: "dollars")
        case .tokens:
            return tokenRingCenter(value)
        case .costPerMtok:
            // $1k 미만 소수 두 자리, 이상 축약; unit 줄은 `MTok`.
            return TotalSpendRingCenter(primary: costPerMtokRingPrimary(value), unit: "MTok")
        }
    }

    /// Cost/MTok hole용 달러 수치 — `$` + $1k 미만 소수 두 자리, 이상 축약.
    private static func costPerMtokRingPrimary(_ value: Double) -> String {
        if abs(value) >= 1000 {
            return "$" + value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
        }
        return Formatters.currency(value, fractionDigits: 2)
    }

    /// token 총량은 크기 단어를 둘째 줄에 배치(`461.8` / `million`) — 10억을 넘어도 hole이 짧게 유지됨.
    private static func tokenRingCenter(_ value: Double) -> TotalSpendRingCenter {
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            let scaled = value / 1_000_000_000
            return TotalSpendRingCenter(
                primary: scaled.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                unit: "billion"
            )
        }
        if magnitude >= 1_000_000 {
            let scaled = value / 1_000_000
            return TotalSpendRingCenter(
                primary: scaled.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                unit: "million"
            )
        }
        if magnitude >= 1_000 {
            let scaled = value / 1_000
            return TotalSpendRingCenter(
                primary: scaled.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
                unit: "thousand"
            )
        }
        return TotalSpendRingCenter(
            primary: value.formatted(.number.precision(.fractionLength(0...1)).locale(locale)),
            unit: "tokens"
        )
    }
}
