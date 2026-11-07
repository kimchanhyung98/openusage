import Foundation

/// `/v1/limits`가 export하는 resource 하나의 안정적 machine-facing metadata.
/// 정규화된 `MetricLine`에서 scalar 선택 방법만 기술 — descriptor 없는 presentation 전용 row는 limits contract에 노출 불가.
struct LimitResourceDescriptor: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Encodable {
        case consumption
        case balance
    }

    enum Source: Hashable, Sendable {
        case progress
        case value(kind: MetricKind, label: String? = nil)
        /// 같은 consumption을 bounded progress 또는 uncapped scalar로 보고하는 provider용.
        case progressOrValue(kind: MetricKind, label: String? = nil)
    }

    let key: String
    let kind: Kind
    let unit: String
    let source: Source
    var estimated = false
}

extension WidgetDescriptor {
    /// widget·provider mapper 변경 없이 scalar 하나를 public limits contract에 추가.
    func exportingLimit(
        _ key: String,
        kind: LimitResourceDescriptor.Kind = .consumption,
        unit: String,
        source: LimitResourceDescriptor.Source = .progress,
        estimated: Bool = false
    ) -> WidgetDescriptor {
        var copy = self
        copy.limitResources.append(LimitResourceDescriptor(
            key: key,
            kind: kind,
            unit: unit,
            source: source,
            estimated: estimated
        ))
        return copy
    }
}
