import Foundation

/// metric row의 측정값 하나 — raw 숫자로 전달, format은 표시 edge(`MetricFormatter`)에서만 수행.
/// 한 row가 값 여러 개 보유 가능(dollars + tokens 등), widget이 `ValueSelection`으로 렌더 대상 선택 —
/// mapper가 한 번만 생산해도 cost 전용·token 전용·combined tile 지원.
struct MetricValue: Hashable, Sendable, Codable {
    /// raw 크기 — `.dollars`는 USD, `.percent`는 0...100, 그 외 절대 count.
    var number: Double
    /// 출력 형식($ / % / count) — row 안에서 값마다 달라 widget이 kind로 선택 가능.
    var kind: MetricKind
    /// 숫자 뒤 단위 명사("tokens", "credits"). nil이면 숫자만 표시 — dollar 금액은 widget의 `unboundedValueWord` 사용.
    var label: String?
    /// 측정·청구가 아닌 local 추정치 여부 — ⓘ note 근거. spend row의 dollar는 추정, token은 실측이라 값 단위 보유.
    var estimated: Bool

    init(number: Double, kind: MetricKind, label: String? = nil, estimated: Bool = false) {
        self.number = number
        self.kind = kind
        self.label = label
        self.estimated = estimated
    }
}

/// widget이 렌더할 row 값의 선택 — `.values` row 하나가 여러 tile을 지원하게 하는 seam.
enum ValueSelection: Hashable, Sendable {
    /// 모든 값을 순서대로 — combined 표시 (예: "$4.08 · 1.2M tokens").
    case all
    /// 한 kind의 값만 — cost 전용은 `.dollars`, token 전용은 `.count`.
    case kind(MetricKind)

    func apply(to values: [MetricValue]) -> [MetricValue] {
        switch self {
        case .all:
            return values
        case .kind(let kind):
            return values.filter { $0.kind == kind }
        }
    }
}
